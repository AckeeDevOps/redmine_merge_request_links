# Fire `redmine_webhook` when an MR merge transitions an issue to "Test ready"

**Date:** 2026-06-16
**Branch:** `feature/webhook-on-merge` (off `feature/change-status-after-merge`)
**Scope:** `redmine_merge_request_links` plugin code + tests only.

## Problem

When a GitLab MR with a fixing keyword (e.g. `resolves #12345`) is merged, the
plugin transitions the issue to **Test ready** via a direct model save inside
`MergeRequest#update_mentioned_issues_status`. That save bypasses
`IssuesController`, so none of `redmine_webhook`'s controller hooks fire and
downstream consumers (the Jira↔Redmine sync) never learn about the transition.

## Root cause (verified)

`redmine_webhook`'s listener (`redmine/plugin-webhooks@master`,
`lib/redmine_webhook/webhook_listener.rb`) only posts from four hooks. The
relevant one, `controller_issues_edit_after_save`, begins with
`return if skip_webhooks(context)`, and:

```ruby
def skip_webhooks(context)
  return true unless context[:request]                        # suppress if no request
  return true if context[:request].headers['X-Skip-Webhooks'] # suppress if header set
  false
end
```

A bare model `save!` triggers none of the four hooks, so nothing posts.

## Approach

Option A(i) from the handover, dispatched from the **controller** (not the model):

The transition runs inside `MergeRequestsController#event` — a live HTTP request
(the GitLab webhook POST) that carries **no** `X-Skip-Webhooks` header. By passing
that request (and the controller as `controller`) into the hook context,
`skip_webhooks` returns `false` and the webhook fires with the same payload *shape*
a normal edit produces. This keeps the whole fix inside MRL with **no change to
`redmine_webhook`**.

Caveat on the `url` field: `controller.issue_url(issue)` builds the URL from the
**incoming request's** host/scheme (Redmine's `ApplicationController` does not set
`default_url_options` from `Setting.host_name`/`Setting.protocol`). Because the URL
is generated inside the GitLab-webhook request, its host/scheme may differ from the
public Redmine host a browser-driven edit would use (e.g. an internal hostname, or
`http` behind a TLS-terminating proxy). The `issue` hash (with the issue id)
is unaffected; only `url` is at risk. See verification item below.

Rejected alternatives:
- **Model dispatches (request threaded in):** smaller diff but couples the model
  to controller/request objects and is harder to unit-test. Rejected for layering.
- **Option B (REST PUT as user 459):** unified edit path but needs the user-459 API
  key wired in and enforces workflow-transition permissions the current direct save
  bypasses — a behavioral-regression risk. Out of scope.

## Design

### Model — `app/models/merge_request.rb`
- Keep the existing transition logic and its defensive `unless issue.save` +
  `logger.warn` (do **not** switch to `save!`: a raise would return HTTP 500 to the
  GitLab webhook handler). Note this does not make `#event` raise-proof — a
  misconfigured `REDMINE_..._REDMINE_USER_ID` still makes `User.find` raise; that is
  pre-existing and out of scope here.
- Expose the transitioned issues via a reader that **always returns an array**:
  `def transitioned_issues; @transitioned_issues ||= []; end`. This is critical —
  the method early-returns on non-merge/blank-env saves, so a plain `attr_reader`
  would leave `@transitioned_issues` `nil` and the controller's `.each` would raise
  `NoMethodError`.
- In `update_mentioned_issues_status`: append an issue only when its save
  **succeeds** (so failed transitions are not announced). The status-only change
  always produces a `JournalDetail`, so `issue.current_journal` is persisted for
  every appended issue.

This threads `transitioned_issues` as model instance state read by the controller
*after* `update!` returns. That is safe here because `#event` performs exactly one
save; if a future code path saved the same `MergeRequest` object twice, the later
save would overwrite the list. Documented intentionally, not refactored away.

### Controller — `app/controllers/merge_requests_controller.rb`
- After `merge_request.update!(attributes)`, loop `merge_request.transitioned_issues`
  and fire the hook:

  ```ruby
  merge_request.transitioned_issues.each do |issue|
    Redmine::Hook.call_hook(
      :controller_issues_edit_after_save,
      issue: issue,
      journal: issue.current_journal,
      controller: self,
      request: request
    )
  end
  ```
- No-op when the list is empty (non-merge events, no fixing keyword, blank env).

### Resulting payload
`{ payload: { action: "updated", issue: {...}, journal: {...}, url: "<issue_url>" } }`
— the same shape a normal `IssuesController#update` edit produces (with the `url`
host/scheme caveat noted above). Delivery is fire-and-forget: `redmine_webhook`
POSTs from a detached `Thread.start` and only logs on failure, so a failed delivery
is invisible to the `#event` response (which still returns `head :ok`).

Tests assert the **hook fires**, not the HTTP POST — the actual delivery is in a
detached thread (untestable and would otherwise be cut off when the test process
exits). mocha ships with Redmine's bundled test harness; `Redmine::Hook.call_hook`
is a plain class method, trivially stubbable. Match leniently on the hook name +
`has_entries(issue: ...)`, not the full argument hash, to avoid brittleness.

- **Functional** (`test/functional/merge_requests_controller_test.rb`): on a
  `merged` GitLab event with a fixing keyword, assert `call_hook` fires with
  `:controller_issues_edit_after_save` for the fixed issue. Cases:
  - single fixed issue → one hook call;
  - **multiple** fixed issues → one hook call per issue (guards the per-save reset
    / aliasing logic);
  - same issue mentioned twice → exactly one hook call (already deduped via `.uniq`);
  - `state != 'merged'` → no hook call;
  - blank env (`REDMINE_..._AFTER_MERGE_STATUS` unset) → no hook call.
- **Unit** (`test/unit/merge_request_test.rb`): on a merged-with-keyword save,
  assert `transitioned_issues` contains the issue **and** its `current_journal` is
  `persisted?` (status-only change creates a `JournalDetail`); assert
  `transitioned_issues == []` (never `nil`) on a non-merge save and a blank-env save.
- Keep existing behavior green: keyword vs. plain-mention issue selection, the
  `state != 'merged'` no-op, and the blank-env no-op.

## Manual verification on redmine-test (no test GitLab available)

There is no test GitLab wired to the test Redmine (prod GitLab only). That's fine —
`/merge_requests/event` is a token-guarded HTTP endpoint, so the "merged" webhook is
forged with `curl`. **Variant 2 means the dispatch happens in the controller, so the
test must go through the HTTP endpoint** — a Rails-console `MergeRequest.update!`
would transition the issue but would NOT fire the webhook.

Prereqs on `redmine-test` (after deploying the fixed plugin per handover §8):
- Env vars: `REDMINE_..._REDMINE_USER_ID=440`, `..._AFTER_MERGE_STATUS=Test ready`,
  `..._FIXING_KEYWORD_PATTERN=<regex>`, `..._GITLAB_WEBHOOK_TOKEN=<token>` (token is
  plain-text in the Helm template, §5).
- A target issue `#<ISSUE_ID>` in a project. No workflow permission needed for user
  440 — the direct `issue.status = ...; issue.save` bypasses workflow checks.
- A `Webhook` row for that project (or `project_id: 0`) pointing at a capture URL
  (e.g. `webhook.site`). The pod needs egress to reach it, else use an in-cluster
  listener.

Forge the merged event (body matches `event_handlers/gitlab.rb` — top-level
`user.username` **and** `object_attributes`, fixing keyword referencing the issue):

```bash
curl -i -X POST https://redmine-upgrade.ack.ee/merge_requests/event \
  -H 'X-Gitlab-Event: Merge Request Hook' \
  -H "X-Gitlab-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"user":{"username":"merge-bot"},"object_attributes":{"url":"https://gitlab.ack.ee/test/project/-/merge_requests/999","title":"resolves #<ISSUE_ID>","description":"resolves #<ISSUE_ID>","state":"merged","iid":999,"target":{"path_with_namespace":"test/project"}}}'
```

(or `kubectl port-forward deploy/redmine-test 8080:3000` and POST to
`http://localhost:8080/merge_requests/event` to avoid exposing the token).

Verify: (1) issue `#<ISSUE_ID>` moved to **Test ready** with a journal by user 440;
(2) the capture endpoint received `{"payload":{"action":"updated","issue":{…},
"journal":{…},"url":"…"}}`; (3) re-sending with `state: "opened"` or no keyword
moves nothing and fires nothing. The payload `url` host reflects whatever host you
POSTed to (the `issue_url` caveat above).

## Out of scope (tracked separately)

- Reconciling the prod baseline (`db75482` + uncommitted zeitwerk shims) and the
  public fork divergence (handover §3).
- Deploy to `redmine-test` and end-to-end verification (handover §8).
- Confirming the target project actually has a `Webhook` row configured — a correct
  fix still posts nothing if the consumer side is unconfigured (handover §9).
- Verifying the `url` host/scheme: compare the GitLab webhook endpoint host against
  the public Redmine host. If the Jira↔Redmine sync relies on `url` (not just the
  issue id), either align the endpoint host or set `default_url_options` so the
  payload URL is browser-usable.
