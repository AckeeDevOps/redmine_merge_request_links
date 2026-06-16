class MergeRequestsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :check_if_login_required

  def event
    event_handler = find_event_handler
    return head :bad_request unless event_handler
    return head :forbidden unless event_handler.verify(request)

    attributes = event_handler.parse_params(params)

    merge_request =
      MergeRequest.find_or_initialize_by(url: attributes[:url])
    merge_request.update!(attributes)

    notify_webhooks(merge_request)

    head :ok
  end

  private

  def find_event_handler
    RedmineMergeRequestLinks.event_handlers.detect do |event_handler|
      event_handler.matches?(request)
    end
  end

  # A merge that transitions issues (e.g. to "Test ready") happens as a direct
  # model save, so redmine_webhook's controller hooks never fire on their own.
  # Re-emit controller_issues_edit_after_save for each transitioned issue,
  # passing the live request (no X-Skip-Webhooks header) and this controller so
  # skip_webhooks lets the post through and the payload carries a real issue_url.
  def notify_webhooks(merge_request)
    merge_request.transitioned_issues.each do |issue|
      Redmine::Hook.call_hook(
        :controller_issues_edit_after_save,
        issue: issue,
        journal: issue.current_journal,
        controller: self,
        request: request
      )
    end
  end
end
