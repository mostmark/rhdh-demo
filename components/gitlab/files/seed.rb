# Seed GitLab for the demo. Runs inside the GitLab pod via `gitlab-rails runner -`.
# The seed Job prepends: APPS, DEMO_GROUP, DEMO_REPO, DEV_GROUP, CURRENT_TOKEN, FILES.
# Idempotent: existing groups, projects and a still-valid token are left alone; the
# demo-layer repo is only updated while it holds nothing but seed commits.

root = User.find_by_username('root') or raise 'root user not found'
org_id = begin
  Organizations::Organization.default_organization&.id
rescue StandardError
  nil
end
log = ->(msg) { puts "seed: #{msg}" }

# People sign in through Keycloak; no self sign-up.
settings = ApplicationSetting.current
if settings.signup_enabled
  settings.update!(signup_enabled: false)
  log.call('disabled sign-up')
end

ensure_group = lambda do |path|
  group = Group.find_by_full_path(path)
  next group if group

  params = { name: path, path: path, visibility_level: Gitlab::VisibilityLevel::PUBLIC }
  params[:organization_id] = org_id if org_id
  res = Groups::CreateService.new(root, params).execute
  group = res.respond_to?(:payload) ? res.payload[:group] : res
  raise "group #{path}: #{group&.errors&.full_messages&.join(', ')}" unless group&.persisted?

  log.call("created group #{path}")
  group
end

demo = ensure_group.call(DEMO_GROUP)
ensure_group.call(DEV_GROUP)

# Demo layer repository (public: Argo CD reads it without credentials; no secrets in it).
full_path = "#{DEMO_GROUP}/#{DEMO_REPO}"
project = Project.find_by_full_path(full_path)
unless project
  params = { name: DEMO_REPO, path: DEMO_REPO, namespace_id: demo.id,
             visibility_level: Gitlab::VisibilityLevel::PUBLIC }
  params[:organization_id] = org_id if org_id
  project = Projects::CreateService.new(root, params).execute
  raise "project #{full_path}: #{project.errors.full_messages.join(', ')}" unless project.persisted?

  log.call("created project #{full_path}")
end
# Seed content: created in an empty repo, and kept up to date (created/updated files,
# nothing deleted) as long as every commit is a seed commit. Once someone else commits,
# the demo layer belongs to them and is left alone.
seed_msg = 'Seed the demo layer'
repo = project.repository
wanted = FILES.transform_values { |c| c.gsub('__APPS_DOMAIN__', APPS) }
if repo.empty?
  actions = wanted.sort.map { |path, content| { action: :create, file_path: path, content: content } }
  repo.commit_files(root, branch_name: 'main', message: seed_msg, actions: actions)
  project.change_head('main') if project.respond_to?(:change_head)
  log.call("seeded #{full_path} with #{actions.size} files")
elsif repo.commits('main', limit: 1000).all? { |c| c.safe_message.to_s.start_with?(seed_msg) }
  actions = wanted.sort.filter_map do |path, content|
    blob = repo.blob_at('main', path)
    if blob.nil?
      { action: :create, file_path: path, content: content }
    else
      blob.load_all_data!
      { action: :update, file_path: path, content: content } if blob.data.b != content.b
    end
  end
  if actions.empty?
    log.call("#{full_path} matches the seed")
  else
    repo.commit_files(root, branch_name: 'main', message: "#{seed_msg} (update)", actions: actions)
    log.call("updated #{full_path}: #{actions.map { |a| a[:file_path] }.join(', ')}")
  end
else
  log.call("#{full_path} has commits besides the seed; not touched")
end

# Token for Developer Hub (catalog discovery, scaffolder publish:gitlab, URL reading).
token = (PersonalAccessToken.find_by_token(CURRENT_TOKEN) rescue nil) unless CURRENT_TOKEN.to_s.empty?
if token&.active?
  log.call('Developer Hub token still valid')
else
  root.personal_access_tokens.where(name: 'rhdh-integration').each { |t| t.revoke! rescue nil }
  attrs = { name: 'rhdh-integration', scopes: %w[api read_repository write_repository],
            expires_at: 364.days.from_now.to_date }
  pat = begin
    root.personal_access_tokens.create!(org_id ? attrs.merge(organization_id: org_id) : attrs)
  rescue ActiveModel::UnknownAttributeError, ActiveRecord::UnknownAttributeError
    root.personal_access_tokens.create!(attrs)
  end
  puts "RHDH_GITLAB_TOKEN=#{pat.token}"
  log.call('created a new Developer Hub token')
end
