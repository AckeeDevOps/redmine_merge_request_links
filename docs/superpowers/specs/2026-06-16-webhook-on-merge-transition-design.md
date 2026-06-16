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
`skip_webhooks` returns `false` and the webhook fires with a real `issue_url` in
the payload — identical to a normal edit. This keeps the whole fix inside MRL with
**no change to `redmine_webhook`**.

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
  GitLab webhook handler).
- Add `attr_reader :transitioned_issues`.
- In `update_mentioned_issues_status`: reset `@transitioned_issues = []` at the top
  (so non-merge saves leave it empty), and append an issue to it only when its save
  **succeeds**.

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
`{ payload: { action: "updated", issue: {...}, journal: {...}, url: "<real issue_url>" } }`
— the same shape a normal `IssuesController#update` edit produces.

## Testing

- **Functional** (`test/functional/merge_requests_controller_test.rb`): on a
  `merged` GitLab event with a fixing keyword, assert
  `Redmine::Hook.call_hook(:controller_issues_edit_after_save, ...)` fires for the
  fixed issue (mocha, bundled with Redmine's test harness). Negative cases:
  `state != 'merged'` → no hook; blank env → no hook.
- **Unit** (`test/unit/merge_request_test.rb`): assert `transitioned_issues` is
  populated on a merged-with-keyword save and empty otherwise.
- Keep existing behavior green: keyword vs. plain-mention issue selection, the
  `state != 'merged'` no-op, and the blank-env no-op.

## Out of scope (tracked separately)

- Reconciling the prod baseline (`db75482` + uncommitted zeitwerk shims) and the
  public fork divergence (handover §3).
- Deploy to `redmine-test` and end-to-end verification (handover §8).
- Confirming the target project actually has a `Webhook` row configured — a correct
  fix still posts nothing if the consumer side is unconfigured (handover §9).
