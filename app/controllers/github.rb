# sync posts from konklone/writing

HMAC_DIGEST = OpenSSL::Digest.new 'sha1'

before '/github/*' do
  halt 403 unless github?

  # be nice to pings
  if github_event == "ping"
    puts "ping: #{JSON.parse(params[:payload]).inspect}"
    halt 200, "Thanks for the ping!"
  end
end

# accept push events, any post with a github field of the URL under discussion
# will be updated (if it needs to be)
post '/github/sync' do
  halt 400, "No thank you" unless github_event == "push"

  push = JSON.parse params[:payload]

  updated = []

  push['commits'].each do |commit|
    puts "Incoming commit: #{commit['id']}"

    # map them all to URLs using the repo URL and the branch this occurred on
    modified = commit['modified'].map do |path|
      Post.github_url_for push['repository']['url'], push['ref'], path
    end

    modified.each do |url|
      puts "Checking for URL: #{url}"

      unless post = Post.where(github: url).first
        puts "\tWe don't have a post for this URL, skipping."
        next
      end

      if post.github_commits.include?(commit['id'])
        puts "\tThis post has seen this commit before, skipping."
        next
      end

      item = post.fetch_from_github
      body = Base64.decode64 item.content
      body.force_encoding "UTF-8"

      # final check to make sure it's not a meaningless change -
      # this is important to ignore merge commits generated by PRs
      if body == post.body
        puts "\tThe post's body is unchanged, skipping."
        next
      end

      # okay, then update the post without syncing back out again
      post.body = body
      post.github_last_message = commit['message']
      post.needs_sync = false

      begin
        puts "\tUpdating post."
        post.save!

        updated << {
          post: post.slug,
          url: url,
          message: commit['message'],
          commit: commit['id']
        }

        # quickly append commit to known commits (don't trigger callbacks)
        post.push github_commits: commit['id']
      rescue Exception => exc
        Email.exception exc
      end
    end
  end

  halt 200, Oj.dump({updated: updated})
end

# logic should match Github's own algorithm at
# https://github.com/github/github-services/blob/f3bb3dd780feb6318c42b2db064ed6d481b70a1f/lib/service/http_helper.rb#L77
def github?
  given_signature = request.env['HTTP_X_HUB_SIGNATURE']

  secret = Environment.config['github']['webhook_secret']
  body = request.body.read
  required_signature = "sha1=" + OpenSSL::HMAC.hexdigest(HMAC_DIGEST, secret, body)

  given_signature == required_signature
end

def github_event
  request.env['HTTP_X_GITHUB_EVENT']
end

# for future reference, assuming defaults for other values,
# how to set the shared secret of a webhook to this site via octokit:
#
# Environment.github.edit_hook "[USER]/[REPO]", [HOOK_ID], "web", {
#   url: "https://[DOMAIN].com/github/sync",
#   content_type: "form", insecure_ssl: "0",
#   secret: "[SHARED SECRET]"
# }