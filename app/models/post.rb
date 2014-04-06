class Post
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Slug

  attr_protected :_id, :slug

  has_many :comments

  field :title

  # slug the title,
  #   :permanent means: don't re-slug automatically (except on initial create)
  slug :title, permanent: true

  field :body
  field :excerpt
  field :nav # generated from body upon save
  field :header # raw html to include in header
  field :footer # raw html to include in footer

  # meta and Open Graph representation
  field :description # 200 char max
  field :image # relative path or URL to image

  # some cached rendered fields
  field :body_rendered
  field :excerpt_rendered
  field :excerpt_text # plain-text

  field :published_at, type: Time
  field :tags, type: Array, default: []

  field :private, type: Boolean, default: false
  field :draft, type: Boolean, default: true
  field :flagged, type: Boolean, default: false

  field :versions, type: Array, default: []

  field :comment_count, type: Integer, default: 0

  field :redirect_url
  field :hacker_news
  field :reddit

  # if set to a github file URL, post *content* field will sync
  field :github

  # REFACTOR: use slugs, not IDs, make editable
  field :related_post_ids, type: Array, default: []

  # MARKEDFORDEATH
  field :display_title, type: Boolean, default: true
  field :post_type, type: Array, default: ["blog"]


  index _slugs: 1
  index published_at: 1
  index post_type: 1
  index tags: 1
  index private: 1
  index draft: 1
  index created_at: 1
  index comment_count: 1
  index related_post_ids: 1

  # index the way posts are found
  index({private: 1, draft: 1, published_at: 1}) # published_at must be last in the index
  index({related_post_ids: 1, published_at: 1})

  index({_slugs: 1, private: 1, draft: 1})

  validates_uniqueness_of :slug, allow_nil: true

  scope :visible, where(private: false, draft: false)
  scope :here, where(redirect_url: {"$in" => [nil, ""]})

  scope :drafts, where(draft: true)
  scope :private, where(private: true)
  scope :flagged, where(flagged: true)

  scope :admin_search, lambda {|query|
    where({"$or" =>
      [:tags, :body, :title, :excerpt, :slug].map {|key| {key => regex_for(query)}}
    })
  }

  scope :tagged, lambda {|tag| where(tags: tag)}

  def update_count!
    self.comment_count = self.comments.ham.count
    self.save!
  end

  def visible?
    !private and !draft
  end

  def related_posts
    @related_posts ||= Post.visible.where(_id: {"$in" => related_post_ids}).desc(:published_at).all
  end

  def self.regex_for(value)
    regex_value = value.dup
    %w{+ ? . * ^ $ ( ) [ ] { } | \ }.each {|char| regex_value.gsub! char, "\\#{char}"}
    /#{regex_value}/i
  end

  # snap current values to the end of the versions array, but don't save
  def snap_version(because)
    version = {
      replaced_at: Time.now,
      replaced_because: because,

      last_updated_at: self.updated_at,
      draft: self.draft,
      private: self.private,

      title: self.title,
      excerpt: self.excerpt,
      body: self.body
    }

    self.versions << version
  end

  # mixing in the rendering methods...
  include ::Helpers::Rendering

  before_validation :correct_capitalization
  def correct_capitalization
    self.body  = capital_H_dangit(self.body)
    self.title = capital_H_dangit(self.title)
    self.excerpt = capital_H_dangit(self.excerpt)
  end

  before_validation :render_fields
  def render_fields
    self.body_rendered = render_post_body self.body
    self.nav = render_post_nav self.body

    # if there's a specific excerpt, use it for the front page and the flat text
    if self.excerpt.present?
      self.excerpt_rendered = render_post_excerpt(self.excerpt)
      self.excerpt_text = render_post_excerpt_text(self.excerpt)

    # otherwise, well we still need some flat (no HTML) text for glimpses, so use the body
    else
      self.excerpt_text = render_post_excerpt_text(self.body)
    end
  end

  # parse a github url into repo, and path to contents
  # e.g. https://github.com/konklone/konklone/blob/master/posts/testing.md
  def self.parse_github_url(url)
    uri = URI.parse url
    parts = uri.path.split "/"
    repo = parts[1..2].join "/"
    branch = parts[4]
    path = parts[5..-1].join "/"
    [repo, branch, path]
  end

  after_save :sync_to_github
  def sync_to_github
    return unless Environment.github.present?
    return unless self.github.present?

    # break up URL into parts
    repo, branch, path = Post.parse_github_url self.github

    # go get the current state
    begin
      item = Environment.github.contents repo, ref: branch, path: path
      sha = item.sha
    rescue Octokit::NotFound
      sha = nil
    end

    # TODO: carry over save message
    message = "Updating post from blog, auto-save"

    begin
      if sha
        puts "Updating post on github at: #{self.github}"
        Environment.github.update_contents repo, path, message, sha, self.body, branch: branch
      else
        puts "Creating post on github at: #{self.github}"
        Environment.github.create_contents repo, path, message, self.body, branch: branch
      end
    rescue Exception => exc
      Email.exception exc
    end

  end

  # TODO: sync from github
end
