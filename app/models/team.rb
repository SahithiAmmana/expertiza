class Team < ApplicationRecord
  has_many :teams_participants, dependent: :destroy
  has_many :users, through: :teams_participants
  has_many :join_team_requests, dependent: :destroy
  has_one :team_node, foreign_key: :node_object_id, dependent: :destroy
  has_many :signed_up_teams, dependent: :destroy
  has_many :bids, dependent: :destroy
  has_many :participants, through: :teams_participants
  has_paper_trail

   # Remove loading based on user_id when user_id is removed from teams_users table
   def self.find_team_for_assignment_and_user(assignment_id, user_id)
    participant = Participant.find_by(user_id: user_id, parent_id: assignment_id)
    team_user = TeamsParticipant.find_by(participant_id: participant.id)
    team_user = TeamsParticipant.where(user_id: user_id).find { |team_user_obj| team_user_obj.team.parent_id == assignment_id } if team_user.nil?
    Team.find(team_user.team_id)
  end

 # E2263 Remove this function when user_id is removed from teams_users table
  # teams_participants table now stores participant_id instead of user_id but, older entries
  # have user_id mapping. This function loads participants details directly from the mapping
  # as well as from user_id if some entries use user_id mapping.
  # Get the participants of the given team
  def participants
    # load based on user_id mapping if it exists
    unless users.to_a.empty?
      participants_list_from_users = users.flat_map(&:participants).select do |participant|
        participant.parent_id == parent_id
      end
    end

    # load directly using participant_ids
    participants_list_from_ids = Participant.where(id: participant_ids)

    unless participants_list_from_users.nil? && participants_list_from_ids.nil?
      participants_list = []
      participants_list += participants_list_from_users unless participants_list_from_users.nil?
      participants_list += participants_list_from_ids unless participants_list_from_ids.nil?
      participants_list
    end
  end
  alias get_participants participants

  # Get the response review map
  def responses
    participants.flat_map(&:responses)
  end

  # Delete the given team
  def delete
    TeamsParticipant.where(team_id: id).find_each(&:destroy)
    node = TeamNode.find_by(node_object_id: id)
    node.destroy if node
    destroy
  end

  # Get the node type of the tree structure
  def node_type
    'TeamNode'
  end

  # Get the names of the users
  def author_names
    names = []
    users.each do |user|
      names << user.fullname
    end
    names
  end

  # Check if the user exist in the team
  # Use participant? function instead wherever possible
  def user?(user)
    participant = AssignmentParticipant.find_by(parent_id: parent_id, user_id: user.id)
    return false if participant.nil?

    participant?(participant)
  end

  # Check if the participant is part of this team
  def participant?(participant)
    participants.include? participant
  end

  # Check if the current team is full?
  def full?
    return false if parent_id.nil? # course team, does not max_team_size

    max_team_members = Assignment.find(parent_id).max_team_size
    curr_team_size = Team.size(id)
    curr_team_size >= max_team_members
  end

  # Add member to the team, changed to hash by E1776
  def add_member(user, _assignment_id = nil)
    raise "The user #{user.name} is already a member of the team #{name}" if user?(user)

    can_add_member = false
    unless full?
      can_add_member = true
      parent = TeamNode.find_by(node_object_id: id)
      participant = AssignmentParticipant.find_by(parent_id: parent_id, user_id: user.id)
      t_user = TeamsParticipant.create(participant_id: participant.id, team_id: id)
      TeamParticipantNode.create(parent_id: parent.id, node_object_id: t_user.id)
      ExpertizaLogger.info LoggerMessage.new('Model:Team', user.name, "Added member to the team #{id}")
    end
    can_add_member
  end

  # Add participant to a team.
  # Raise exception if the participant is already part of this team.
  def add_participant_to_team(participant, _assignment_id = nil)
    raise "The user #{participant.name} is already a member of the team #{name}" if user?(participant.user)

    can_add_member = false
    unless full?
      can_add_member = true
      t_user = TeamsParticipant.create(participant_id: participant.id, team_id: id)
      parent = TeamNode.find_by(node_object_id: id)
      TeamParticipantNode.create(parent_id: parent.id, node_object_id: t_user.id)
      ExpertizaLogger.info LoggerMessage.new('Model:Team', participant.name, "Added member to the team #{id}")
    end
    can_add_member
  end

  # Define the size of the team,
  def self.size(team_id)
    TeamsParticipant.where(team_id: team_id).count
  end

  # Copy method to copy this team
  def copy_members(new_team)
    members = TeamsParticipant.where(team_id: id)
    members.each do |member|
      t_user = TeamsParticipant.create(team_id: new_team.id, user_id: member.user_id)
      parent = Object.const_get(parent_model).find(parent_id)
      TeamParticipantNode.create(parent_id: parent.id, node_object_id: t_user.id)
    end
  end

  # Check if the team exists
  def self.check_for_existing(parent, name, team_type)
    list = Object.const_get(team_type + 'Team').where(parent_id: parent.id, name: name)
    raise TeamExistsError, "The team name #{name} is already in use." unless list.empty?
  end

  # Algorithm
  # Start by adding single members to teams that are one member too small.
  # Add two-member teams to teams that two members too small. etc.
  def self.randomize_all_by_parent(parent, team_type, min_team_size)
    participants = Participant.where(parent_id: parent.id, type: parent.class.to_s + 'Participant')
    participants = participants.sort { rand(-1..1) }
    users = participants.map { |p| User.find(p.user_id) }.to_a
    # find teams still need team members and users who are not in any team
    teams = Team.where(parent_id: parent.id, type: parent.class.to_s + 'Team').to_a
    teams_num = teams.size
    i = 0
    teams_num.times do
      teams_participants = TeamsParticipant.where(team_id: teams[i].id)
      teams_participants.each do |teams_user|
        if !teams_user.user_id.nil?
          users.delete(User.find(teams_user.user_id))
        end
      end
      if Team.size(teams.first.id) >= min_team_size
        teams.delete(teams.first)
      else
        i += 1
      end
    end
    # sort teams by decreasing team size
    teams.sort_by { |team| Team.size(team.id) }.reverse!
    # insert users who are not in any team to teams still need team members
    assign_single_users_to_teams(min_team_size, parent, teams, users) if !users.empty? && !teams.empty?
    # If all the existing teams are fill to the min_team_size and we still have more users, create teams for them.
    create_team_from_single_users(min_team_size, parent, team_type, users) unless users.empty?
  end

  def self.create_team_from_single_users(min_team_size, parent, team_type, users)
    num_of_teams = users.length.fdiv(min_team_size).ceil
    next_team_member_index = 0
    (1..num_of_teams).to_a.each do |i|
      team = Object.const_get(team_type + 'Team').create(name: 'Team_' + i.to_s, parent_id: parent.id)
      TeamNode.create(parent_id: parent.id, node_object_id: team.id)
      min_team_size.times do
        break if next_team_member_index >= users.length

        user = users[next_team_member_index]
        team.add_member(user, parent.id)
        next_team_member_index += 1
      end
    end
  end

  def self.assign_single_users_to_teams(min_team_size, parent, teams, users)
    teams.each do |team|
      curr_team_size = Team.size(team.id)
      member_num_difference = min_team_size - curr_team_size
      while member_num_difference > 0
        team.add_member(users.first, parent.id)
        users.delete(users.first)
        member_num_difference -= 1
        break if users.empty?
      end
      break if users.empty?
    end
  end

  # Generate the team name
  def self.generate_team_name(_team_name_prefix = '')
    counter = 1
    loop do
      team_name = "Team_#{counter}"
      return team_name unless Team.find_by(name: team_name)

      counter += 1
    end
  end

  # Extract team members from the csv and push to DB,  changed to hash by E1776
  def import_team_members(row_hash)
    row_hash[:teammembers].each_with_index do |teammate, _index|
      user = User.find_by(name: teammate.to_s)
      if user.nil?
        raise ImportError, "The user '#{teammate}' was not found. <a href='/users/new'>Create</a> this user?"
      else
        add_member(user) if TeamsParticipant.find_by_team_id_and_user_id(id, user.id).nil?
      end
    end
  end

  #  changed to hash by E1776
  def self.import(row_hash, id, options, teamtype)
    raise ArgumentError, 'Not enough fields on this line.' if row_hash.empty? || (row_hash[:teammembers].empty? && (options[:has_teamname] == 'true_first' || options[:has_teamname] == 'true_last')) || (row_hash[:teammembers].empty? && (options[:has_teamname] == 'true_first' || options[:has_teamname] == 'true_last'))

    if options[:has_teamname] == 'true_first' || options[:has_teamname] == 'true_last'
      name = row_hash[:teamname].to_s
      team = where(['name =? && parent_id =?', name, id]).first
      team_exists = !team.nil?
      name = handle_duplicate(team, name, id, options[:handle_dups], teamtype)
    else
      if teamtype.is_a?(CourseTeam)
        name = generate_team_name(Course.find(id).name)
      elsif teamtype.is_a?(AssignmentTeam)
        name = generate_team_name(Assignment.find(id).name)
      end
    end
    if name
      team = Object.const_get(teamtype.to_s).create_team_and_node(id)
      team.name = name
      team.save
    end

    # insert team members into team unless team was pre-existing & we ignore duplicate teams

    team.import_team_members(row_hash) unless team_exists && options[:handle_dups] == 'ignore'
  end

  # Handle existence of the duplicate team
  def self.handle_duplicate(team, name, id, handle_dups, teamtype)
    return name if team.nil? # no duplicate
    return nil if handle_dups == 'ignore' # ignore: do not create the new team

    if handle_dups == 'rename' # rename: rename new team
      if teamtype.is_a?(CourseTeam)
        return generate_team_name(Course.find(id).name)
      elsif  teamtype.is_a?(AssignmentTeam)
        return generate_team_name(Assignment.find(id).name)
      end
    end
    if handle_dups == 'replace' # replace: delete old team
      team.delete
      return name
    else # handle_dups = "insert"
      return nil
    end
  end

  # Export the teams to csv
  def self.export(csv, parent_id, options, teamtype)
    if teamtype.is_a?(CourseTeam)
      teams = CourseTeam.where(parent_id: parent_id)
    elsif teamtype.is_a?(AssignmentTeam)
      teams = AssignmentTeam.where(parent_id: parent_id)
    end
    teams.each do |team|
      output = []
      output.push(team.name)
      if options[:team_name] == 'false'
        team_members = TeamsParticipant.where(team_id: team.id)
        team_members.each do |user|
          output.push(user.name)
        end
      end
      csv << output
    end
    csv
  end

  # Create the team with corresponding tree node
  def self.create_team_and_node(id)
    parent = parent_model id # current_task will be either a course object or an assignment object.
    team_name = Team.generate_team_name(parent.name)
    team = create(name: team_name, parent_id: id)
    # new teamnode will have current_task.id as parent_id and team_id as node_object_id.
    TeamNode.create(parent_id: id, node_object_id: team.id)
    ExpertizaLogger.info LoggerMessage.new('Model:Team', '', "New TeamNode created with teamname #{team_name}")
    team
  end

  # E1991 : This method allows us to generate
  # team names based on whether anonymized view
  # is set or not. The logic is similar to
  # existing logic of User model.
  def name(ip_address = nil)
    if User.anonymized_view?(ip_address)
      return "Anonymized_Team_#{self[:id]}"
    else
      return self[:name]
    end
  end

  # REFACTOR END:: class methods import export moved from course_team & assignment_team to here

  # Create the team with corresponding tree node and given users
  def self.create_team_with_users(parent_id, user_ids)
    team = create_team_and_node(parent_id)

    user_ids.each do |user_id|
      remove_user_from_previous_team(parent_id, user_id)

      # Create new team_user and team_user node
      team.add_member(User.find(user_id))
    end
    team
  end

  # Removes the specified user from any team of the specified assignment
  def self.remove_user_from_previous_team(parent_id, user_id)
    participant = Participant.find_by(user_id: user_id, parent_id: parent_id)
    team_user = TeamsParticipant.find_by(participant_id: participant.id)
    team_user = TeamsParticipant.where(user_id: user_id).find { |team_user_obj| team_user_obj.team.parent_id == parent_id } if team_user.nil?    
    begin
      team_user.destroy
    rescue StandardError
      nil
    end
  end
end
