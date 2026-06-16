require File.expand_path('../../test_helper', __FILE__)

# Stand-in for redmine_webhook's listener (a Singleton, like the real
# RedmineWebhook::WebhookListener). The controller dispatches the webhook by
# calling THIS listener directly — not via Redmine::Hook.call_hook — so that
# only redmine_webhook reacts and co-listeners on the shared
# controller_issues_edit_after_save hook (e.g. redmine_checklists, which needs
# IssuesController-only state) are not dragged in and crashed.
module RedmineWebhook
  class WebhookListener < Redmine::Hook::Listener
    cattr_accessor :captured
    self.captured = []

    def controller_issues_edit_after_save(context = {})
      self.class.captured << context
      ''
    end
  end
end

# Generic listener registered on the shared hook. If the controller ever went
# back to broadcasting via call_hook, this would record — so an empty capture
# proves the dispatch stayed targeted.
class IssueWebhookHookSpy < Redmine::Hook::Listener
  cattr_accessor :captured
  self.captured = []

  def controller_issues_edit_after_save(context = {})
    self.class.captured << context
    ''
  end
end

class MergeRequestsControllerTest < ActionController::TestCase
  include RedmineMergeRequestLinks::RequestTestHelperCompat

  TOKEN = 'secret'
  MERGE_REQUEST_URL = 'https://gitlab.example.com/project/merge_requests/1'

  fixtures :all

  def setup
    IssueWebhookHookSpy.captured = []
    RedmineWebhook::WebhookListener.captured = []
    RedmineMergeRequestLinks.event_handlers = [
      RedmineMergeRequestLinks::EventHandlers::Gitea.new(token: TOKEN),
      RedmineMergeRequestLinks::EventHandlers::Github.new(token: TOKEN),
      RedmineMergeRequestLinks::EventHandlers::Gitlab.new(token: TOKEN)
    ]
  end

  def test_gitlab_merge_request_event_creates_merge_request
    request.headers['X-Gitlab-Event'] = 'Merge Request Hook'
    request.headers['X-Gitlab-Token'] = 'secret'
    post(:event,
         user: {
           username: 'john'
         },
         object_attributes: {
           url: MERGE_REQUEST_URL,
           title: 'Some merge request',
           state: 'opened',
           iid: 23,
           target: {
             path_with_namespace: 'group/project'
           }
         })

    assert_response :success

    merge_request = MergeRequest.where(url: MERGE_REQUEST_URL).first
    assert merge_request.present?
    assert_equal 'opened', merge_request.state
    assert_equal 'Some merge request', merge_request.title
    assert_equal 'group/project!23', merge_request.display_id
    assert_equal '@john', merge_request.author_name
    assert_equal 'gitlab', merge_request.provider
  end

  def test_gitlab_merge_request_event_updates_merge_request
    merge_request = MergeRequest.create!(
      url: MERGE_REQUEST_URL,
      title: 'Old title',
      state: 'opened'
    )

    request.headers['X-Gitlab-Event'] = 'Merge Request Hook'
    request.headers['X-Gitlab-Token'] = 'secret'
    post(:event,
         user: {
           username: 'john'
         },
         object_attributes: {
           url: MERGE_REQUEST_URL,
           title: 'New title',
           state: 'merged',
           iid: 23,
           target: {
             path_with_namespace: 'group/project'
           }
         })

    assert_response :success

    merge_request.reload
    assert_equal 'merged', merge_request.state
    assert_equal 'New title', merge_request.title
  end

  def test_does_not_update_author_field
    # Gitlab does not pass the author name, only the name of the user
    # performing the current action. Since (except for merge requests
    # that were created before the plugin was installed) the user
    # triggering the first webhook event is the author, we want to
    # update the author name only once.

    merge_request = MergeRequest.create!(
      url: MERGE_REQUEST_URL,
      title: 'Title',
      state: 'opened',
      author_name: '@jack'
    )

    request.headers['X-Gitlab-Event'] = 'Merge Request Hook'
    request.headers['X-Gitlab-Token'] = 'secret'
    post(:event,
         user: {
           username: 'john'
         },
         object_attributes: {
           url: MERGE_REQUEST_URL,
           title: 'Title',
           state: 'merged',
           iid: 23,
           target: {
             path_with_namespace: 'group/project'
           }
         })

    assert_response :success

    merge_request.reload
    assert_equal '@jack', merge_request.author_name
  end

  def test_gitlab_system_hooks
    request.headers['X-Gitlab-Event'] = 'System Hook'
    request.headers['X-Gitlab-Token'] = 'secret'
    post(:event,
         event_type: 'merge_request',
         user: {
           username: 'john'
         },
         object_attributes: {
           url: MERGE_REQUEST_URL,
           title: 'Some merge request',
           state: 'opened',
           iid: 23,
           target: {
             path_with_namespace: 'group/project'
           }
         })

    assert_response :success

    merge_request = MergeRequest.where(url: MERGE_REQUEST_URL).first
    assert merge_request.present?
    assert_equal 'opened', merge_request.state
    assert_equal 'Some merge request', merge_request.title
    assert_equal 'group/project!23', merge_request.display_id
    assert_equal '@john', merge_request.author_name
  end

  def test_responds_with_forbidden_if_gitlab_token_does_not_match
    request.headers['X-Gitlab-Event'] = 'Merge Request Hook'
    request.headers['X-Gitlab-Token'] = 'wrong'
    post(:event,
         user: {
           username: 'john'
         },
         object_attributes: {
           url: MERGE_REQUEST_URL,
           title: 'Some merge request',
           state: 'opened',
           iid: 23,
           target: {
             path_with_namespace: 'group/project'
           }
         })

    assert_response :forbidden
  end

  def test_associates_issues_mentioned_in_gitlab_mr_description
    issue = Issue.first

    request.headers['X-Gitlab-Event'] = 'Merge Request Hook'
    request.headers['X-Gitlab-Token'] = 'secret'
    post(:event,
         user: {
           username: 'john'
         },
         object_attributes: {
           url: MERGE_REQUEST_URL,
           title: 'Some merge request',
           state: 'opened',
           description: "This mentions ##{issue.id}",
           iid: 23,
           target: {
             path_with_namespace: 'group/project'
           }
         })

    merge_request = MergeRequest.where(url: MERGE_REQUEST_URL).first
    assert_includes(merge_request.issues, issue)
  end

  def test_associates_issues_mentioned_in_gitlab_mr_title
    issue = Issue.first

    request.headers['X-Gitlab-Event'] = 'Merge Request Hook'
    request.headers['X-Gitlab-Token'] = 'secret'
    post(:event,
         user: {
           username: 'john'
         },
         object_attributes: {
           url: MERGE_REQUEST_URL,
           title: "Some merge request (##{issue.id})",
           state: 'opened',
           description: 'Some text',
           iid: 23,
           target: {
             path_with_namespace: 'group/project'
           }
         })

    merge_request = MergeRequest.where(url: MERGE_REQUEST_URL).first
    assert_includes(merge_request.issues, issue)
  end

  def test_github_pull_request_event_creates_merge_request
    url = 'https://github.com/Codertocat/Hello-World/pull/1'

    payload = {
      pull_request: {
        html_url: url,
        title: 'Some pull request',
        state: 'closed',
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Hub-Signature'] = hub_signature(payload)
    post(:event, payload)

    assert_response :success

    merge_request = MergeRequest.where(url: url).first
    assert merge_request.present?
    assert_equal 'closed', merge_request.state
    assert_equal 'Some pull request', merge_request.title
    assert_equal 'group/project#12', merge_request.display_id
    assert_equal '@someuser', merge_request.author_name
    assert_equal 'github', merge_request.provider
  end

  def test_responds_with_forbidden_if_github_signature_is_incorrect
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Hub-Signature'] = 'wrong'
    post(:event, pull_request: {
           html_url: 'https://github.com/Codertocat/Hello-World/pull/1',
           title: 'Some pull request',
           state: 'closed',
           number: 12,
           user: {
             login: 'someuser'
           },
           base: {
             repo: {
               full_name: 'group/project'
             }
           }
         })

    assert_response :forbidden
  end

  def test_associates_issues_mentioned_in_github_pr_body
    url = 'https://github.com/Codertocat/Hello-World/pull/1'
    issue = Issue.last

    payload = {
      pull_request: {
        html_url: url,
        title: 'Some pull request',
        state: 'closed',
        body: "Talks about ##{issue.id}",
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Hub-Signature'] = hub_signature(payload)
    post(:event, payload)

    merge_request = MergeRequest.where(url: url).first
    assert_includes(merge_request.issues, issue)
  end

  def test_associates_issues_mentioned_in_github_pr_title
    url = 'https://github.com/Codertocat/Hello-World/pull/1'
    issue = Issue.last

    payload = {
      pull_request: {
        html_url: url,
        title: "Some pull request (##{issue.id})",
        state: 'closed',
        body: 'Some text',
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Hub-Signature'] = hub_signature(payload)
    post(:event, payload)

    merge_request = MergeRequest.where(url: url).first
    assert_includes(merge_request.issues, issue)
  end

  def test_sets_state_to_merged_if_closed_and_merged
    url = 'https://github.com/Codertocat/Hello-World/pull/1'

    payload = {
      pull_request: {
        html_url: url,
        title: 'Some pull request',
        state: 'closed',
        merged: true,
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Hub-Signature'] = hub_signature(payload)
    post(:event, payload)

    assert_response :success

    merge_request = MergeRequest.where(url: url).first
    assert_equal 'merged', merge_request.state
  end

  def test_gitea_pull_request_event_creates_merge_request
    url = 'https://gitea.com/Codertocat/Hello-World/pull/1'

    payload = {
      pull_request: {
        html_url: url,
        title: 'Some pull request',
        state: 'closed',
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-Gitea-Event'] = 'pull_request'
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Gogs-Event'] = 'pull_request'
    request.headers['X-Gitea-Signature'] = gitea_signature(payload)
    request.headers['X-Gogs-Signature'] = gitea_signature(payload)

    post(:event, payload)

    assert_response :success

    merge_request = MergeRequest.where(url: url).first
    assert merge_request.present?
    assert_equal 'closed', merge_request.state
    assert_equal 'Some pull request', merge_request.title
    assert_equal 'group/project#12', merge_request.display_id
    assert_equal '@someuser', merge_request.author_name
    assert_equal 'gitea', merge_request.provider
  end

  def test_responds_with_forbidden_if_gitea_signature_is_incorrect
    request.headers['X-Gitea-Event'] = 'pull_request'
    request.headers['X-Gitea-Signature'] = 'wrong'
    request.headers['X-Gogs-Event'] = 'pull_request'
    request.headers['X-Gogs-Signature'] = 'wrong'
    post(:event, pull_request: {
           html_url: 'https://gitea.com/Codertocat/Hello-World/pull/1',
           title: 'Some pull request',
           state: 'closed',
           number: 12,
           user: {
             login: 'someuser'
           },
           base: {
             repo: {
               full_name: 'group/project'
             }
           }
         })

    assert_response :forbidden
  end

  def test_associates_issues_mentioned_in_gitea_pr_body
    url = 'https://gitea.com/Codertocat/Hello-World/pull/1'
    issue = Issue.last

    payload = {
      pull_request: {
        html_url: url,
        title: 'Some pull request',
        state: 'closed',
        body: "Talks about ##{issue.id}",
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-Gitea-Event'] = 'pull_request'
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Gogs-Event'] = 'pull_request'
    request.headers['X-Gitea-Signature'] = gitea_signature(payload)
    request.headers['X-Gogs-Signature'] = gitea_signature(payload)
    post(:event, payload)

    merge_request = MergeRequest.where(url: url).first
    assert_includes(merge_request.issues, issue)
  end

  def test_associates_issues_mentioned_in_gitea_pr_title
    url = 'https://gitea.com/Codertocat/Hello-World/pull/1'
    issue = Issue.last

    payload = {
      pull_request: {
        html_url: url,
        title: "Some pull request (##{issue.id})",
        state: 'closed',
        body: 'Some text',
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-Gitea-Event'] = 'pull_request'
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Gogs-Event'] = 'pull_request'
    request.headers['X-Gitea-Signature'] = gitea_signature(payload)
    request.headers['X-Gogs-Signature'] = gitea_signature(payload)
    post(:event, payload)

    merge_request = MergeRequest.where(url: url).first
    assert_includes(merge_request.issues, issue)
  end

  def test_sets_state_to_merged_if_gitea_pr_is_closed_and_merged
    url = 'https://gitea.com/Codertocat/Hello-World/pull/1'

    payload = {
      pull_request: {
        html_url: url,
        title: 'Some pull request',
        state: 'closed',
        merged: true,
        number: 12,
        user: {
          login: 'someuser'
        },
        base: {
          repo: {
            full_name: 'group/project'
          }
        }
      }
    }
    request.headers['X-Gitea-Event'] = 'pull_request'
    request.headers['X-GitHub-Event'] = 'pull_request'
    request.headers['X-Gogs-Event'] = 'pull_request'
    request.headers['X-Gitea-Signature'] = gitea_signature(payload)
    request.headers['X-Gogs-Signature'] = gitea_signature(payload)
    post(:event, payload)

    assert_response :success

    merge_request = MergeRequest.where(url: url).first
    assert_equal 'merged', merge_request.state
  end

  def test_responds_with_bad_request_if_unknown_event
    post(:event)

    assert_response :bad_request
  end

  def test_dispatches_webhook_to_redmine_webhook_listener_on_merge
    issue = Issue.find(1)

    with_merge_status_env do
      post_gitlab_merge_event(title: "resolves ##{issue.id}")

      assert_response :success
      assert_equal('Resolved', issue.reload.status.name)

      # Dispatched directly to redmine_webhook's listener...
      assert_equal(1, RedmineWebhook::WebhookListener.captured.size)
      context = RedmineWebhook::WebhookListener.captured.first
      assert_equal(issue, context[:issue])
      # request + controller must be present so redmine_webhook's skip_webhooks
      # does not suppress the post.
      assert_instance_of(MergeRequestsController, context[:controller])
      assert_not_nil(context[:request])
      assert(context[:journal].present? && context[:journal].persisted?,
             'expected a persisted journal in the dispatch context')

      # ...and NOT broadcast via call_hook to co-listeners on the shared hook.
      assert_empty(IssueWebhookHookSpy.captured)
    end
  end

  def test_dispatches_webhook_for_each_fixed_issue
    issue_one = Issue.find(1)
    issue_two = Issue.find(2)

    with_merge_status_env do
      post_gitlab_merge_event(title: "resolves ##{issue_one.id}",
                              description: "also resolves ##{issue_two.id}")

      assert_response :success

      dispatched = RedmineWebhook::WebhookListener.captured.map { |c| c[:issue] }
      assert_equal([issue_one, issue_two].sort_by(&:id), dispatched.sort_by(&:id))
      assert_empty(IssueWebhookHookSpy.captured)
    end
  end

  def test_dispatches_webhook_once_when_same_issue_mentioned_twice
    issue = Issue.find(1)

    with_merge_status_env do
      post_gitlab_merge_event(title: "resolves ##{issue.id}",
                              description: "resolves ##{issue.id} again")

      assert_response :success
      assert_equal(1, RedmineWebhook::WebhookListener.captured.size)
    end
  end

  def test_does_not_dispatch_webhook_when_not_merged
    issue = Issue.find(1)

    with_merge_status_env do
      post_gitlab_merge_event(title: "resolves ##{issue.id}", state: 'opened')

      assert_response :success
      assert_empty(RedmineWebhook::WebhookListener.captured)
    end
  end

  def test_does_not_dispatch_webhook_when_status_env_blank
    issue = Issue.find(1)

    post_gitlab_merge_event(title: "resolves ##{issue.id}")

    assert_response :success
    assert_empty(RedmineWebhook::WebhookListener.captured)
  end

  private

  def post_gitlab_merge_event(title:, state: 'merged', description: nil)
    request.headers['X-Gitlab-Event'] = 'Merge Request Hook'
    request.headers['X-Gitlab-Token'] = TOKEN
    attributes = {
      url: MERGE_REQUEST_URL,
      title: title,
      state: state,
      iid: 23,
      target: { path_with_namespace: 'group/project' }
    }
    attributes[:description] = description unless description.nil?
    post(:event, user: { username: 'john' }, object_attributes: attributes)
  end

  def with_merge_status_env
    vars = {
      'REDMINE_MERGE_REQUEST_LINKS_REDMINE_USER_ID' => '2',
      'REDMINE_MERGE_REQUEST_LINKS_AFTER_MERGE_STATUS' => 'Resolved',
      'REDMINE_MERGE_REQUEST_LINKS_FIXING_KEYWORD_PATTERN' =>
        '(?:clos(?:e[sd]?|ing)|fix(?:e[sd]|ing)?|resolv(?:e[sd]?|ing))'
    }
    previous = {}
    vars.each { |key, value| previous[key] = ENV[key]; ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def hub_signature(payload)
    'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'),
                                      TOKEN,
                                      payload.to_query)
  end

  def gitea_signature(payload)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                                      TOKEN,
                                      payload.to_query)
  end
end
