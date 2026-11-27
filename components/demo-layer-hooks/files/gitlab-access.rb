# Runs in the GitLab pod (gitlab-rails runner). The hook prepends ORG (the demo
# organisation, same JSON as keycloak/demo-org), DEV_GROUP and DRY_RUN.
#
# Gives every person in the demo organisation the Developer role in DEV_GROUP, the group
# the software templates create repositories in, and lets Developers push and merge to
# the default branch there (new and existing repositories), so pushes from Dev Spaces
# start the CI pipeline. People are matched by username: GitLab signs them in through
# Keycloak with uid_field preferred_username, so a GitLab account is pre-created with that
# identity and the first sign-in uses it.
# Removes the Developer membership of people who left the organisation (only accounts
# with a Keycloak identity; admins, bots and other roles are left alone). Never deletes
# GitLab accounts.
require 'securerandom'

log = ->(msg) { puts "access: #{DRY_RUN ? '(dry run) ' : ''}#{msg}" }
root = User.find_by_username('root') || raise('no root user')
group = Group.find_by_full_path(DEV_GROUP) || raise("no group #{DEV_GROUP}")
dev = Gitlab::Access::DEVELOPER
people = (ORG['teams'] || []).flat_map { |t| t['members'] || [] }.uniq { |m| m['username'] }
wanted = people.map { |m| m['username'] }
org_id = group.respond_to?(:organization_id) ? group.organization_id : nil

people.each do |p|
  user = User.find_by_username(p['username'])
  unless user
    if DRY_RUN
      log.call("would create #{p['username']}")
      next
    end
    pw = SecureRandom.base64(32)
    params = { username: p['username'], email: p['email'],
               name: [p['firstName'], p['lastName']].compact.join(' '),
               password: pw, password_confirmation: pw, password_automatically_set: true,
               skip_confirmation: true, extern_uid: p['username'], provider: 'openid_connect' }
    params[:organization_id] = org_id if org_id
    res = Users::CreateService.new(root, params).execute
    user = res.respond_to?(:payload) ? res.payload[:user] : res
    unless user&.persisted?
      log.call("could not create #{p['username']}: #{user&.errors&.full_messages&.join(', ') || res.try(:message)}")
      next
    end
    log.call("created #{p['username']}")
  end
  level = group.max_member_access_for_user(user)
  next if level >= dev
  if DRY_RUN
    log.call("would add #{p['username']} as Developer")
  else
    group.add_member(user, dev)
    log.call("added #{p['username']} as Developer")
  end
end

group.members.where(access_level: dev).includes(:user).each do |m|
  u = m.user
  next if u.nil? || u.admin? || u.bot? || wanted.include?(u.username)
  next unless u.identities.exists?(provider: 'openid_connect')
  if DRY_RUN
    log.call("would remove #{u.username}")
  else
    m.destroy
    log.call("removed #{u.username} (no longer in the organisation)")
  end
end

# Branch protection: Developers may push and merge to the default branch.
want = { 'allowed_to_push' => [{ 'access_level' => dev }],
         'allowed_to_merge' => [{ 'access_level' => dev }],
         'allow_force_push' => false, 'developer_can_initial_push' => false }
ns = group.namespace_settings
current = (ns.default_branch_protection_defaults || {}).to_h.deep_stringify_keys
if current.slice(*want.keys) != want
  if DRY_RUN
    log.call("would set default branch protection of #{DEV_GROUP} (now #{current.inspect})")
  else
    ns.update!(default_branch_protection_defaults: want)
    log.call("set default branch protection of #{DEV_GROUP}: Developers push and merge")
  end
end
group.all_projects.each do |project|
  branch = project.protected_branches.find_by(name: project.default_branch)
  next unless branch
  %i[push_access_levels merge_access_levels].each do |kind|
    levels = branch.public_send(kind).select { |a| a.respond_to?(:role?) ? a.role? : a.user_id.nil? && a.group_id.nil? }
    next if levels.any? { |a| a.access_level <= dev && a.access_level > Gitlab::Access::NO_ACCESS }
    if DRY_RUN
      log.call("would allow Developers: #{project.full_path} #{branch.name} #{kind}")
    elsif levels.any?
      levels.first.update!(access_level: dev)
      log.call("#{project.full_path} #{branch.name}: Developers allowed (#{kind})")
    else
      branch.public_send(kind).create!(access_level: dev)
      log.call("#{project.full_path} #{branch.name}: Developers allowed (#{kind})")
    end
  end
end
log.call("#{wanted.size} people, #{group.members.where(access_level: dev).count} Developers in #{DEV_GROUP}")
