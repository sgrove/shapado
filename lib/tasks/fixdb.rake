class Question
  def set_created_at; end
  def set_updated_at; end
end

class Answer
  def set_created_at; end
  def set_updated_at; end
end

class Group
  def set_created_at; end
  def set_updated_at; end
end

desc "Fix all"
task :fixall => [:environment, "fixdb:questions", "fixdb:dates", "fixdb:openid", "fixdb:groups", "fixdb:relocate", "fixdb:counters", "fixdb:sync_counts", "fixdb:votes", "fixdb:last_target_type", "fixdb:comments", "fixdb:widgets"] do
end

namespace :fixdb do
  task :questions => [:environment] do
    Question.all.each do |question|
      question.override(:_random => rand())
      question.override(:_random_times => 0.0)

      watchers = question["watchers"]
      question.unset(:watchers => true)
      if !watchers.blank?
        question.override(:follower_ids => watchers)
      end
    end
  end

  task :dates => [:environment] do
    %w[badges questions comments votes users announcements groups memberships pages reputation_events user_stats versions views_counts].each do |cname|
      coll = Mongoid.master.collection(cname)
      coll.find.each do |q|
        %w[activity_at last_target_date created_at updated_at birthday last_logged_at starts_at ends_at last_activity_at time date].each do |key|
          if q[key].is_a?(String)
            q[key] = Time.parse(q[key])
          end
        end
        coll.save(q)
      end
    end
  end

  task :openid => [:environment] do
    User.all.each do |user|
      next if user.identity_url.blank?

      puts "Updating: #{user.login}"
      user.push_uniq(:auth_keys => "open_id_#{user[:identity_url]}")
      user.unset(:identity_url => 1)
    end
  end

  task :sync_counts => [:environment] do
    votes = Mongoid.database.collection("votes")
    comments = Mongoid.database.collection("comments")
    puts "updating comment's counts"
    comments.find.each do |c|
      print "."
      votes_average=0
      votes.find(:voteable_id =>  c["_id"]).each do |v|
        votes_average+=v["value"]
      end
      comments.update({:_id => c["id"]},
                      {"$set" => {"votes_count" => votes.find(:voteable_id =>  c["_id"]).count,
                                  "votes_average" => votes_average}})

      if c["flags"]
        comments.update({:_id => c["id"]}, {"$set" => {"flags_count" => c["flags"].size}})
      end
    end

    puts "updating questions's counts"
    Question.all.each do |q|
      print "."
      votes_average=0
      q.votes.each {|e| votes_average+=e.value }
      q.override("flags_count" => q.flags.size, "votes_count" => q.votes.size, "votes_average" => votes_average)
    end
  end

  task :counters => :environment do
    Question.all.each do |q|
      q.override(:close_requests_count => q.close_requests.size)
      q.override(:open_requests_count => q.open_requests.size)
    end
  end

  task :last_target_type => [:environment] do
    puts "updating questions#last_target_type"
    Question.all(:conditions => {:last_target_type.ne => nil}).each do |q|
      print "."
      if(q.last_target_type != "Comment")
        last_target = q.last_target_type.constantize.find(q.last_target_id)
      else
        data = Mongoid.database.collection("comments").find_one(:_id => q.last_target_id)
        last_target = Comment.new(data)
#         p last_target.id
#         p Mongoid.database.collection("comments").find_one(:_id => q.last_target_id)
      end

      if(last_target)
        if(last_target.respond_to?(:updated_at) && last_target.updated_at && last_target.updated_at.is_a?(String))
          last_target.updated_at = Time.parse(last_target.updated_at)
        end
        Question.update_last_target(q.id, last_target)
      end
    end
  end

  task :votes => [:environment] do
    puts "updating votes"
    Group.all.each do |group|
      count = 0

      comments = Mongoid.database.collection("comments")
      questions = Mongoid.database.collection("questions")
      Mongoid.database.collection("votes").find({:group_id => group["_id"]}).each do |vote|
        vote.delete("group_id")
        id = vote.delete("voteable_id")
        klass = vote.delete("voteable_type")
        collection = comments
        if klass == "Question"
          collection = questions;
        end
        count += 1
        collection.update({:_id => id}, "$addToSet" => {:votes => vote})
      end
      if count > 0
        puts "Updated #{count} #{group["name"]} votes"
      end
    end
    Mongoid.database.collection("votes").drop
  end

  task :comments => [:environment] do
    puts "updating comments"
    comments = Mongoid.database.collection("comments")
    questions = Mongoid.database.collection("questions")

    Mongoid.database.collection("comments").find(:_type => "Comment").each do |comment|
        id = comment.delete("commentable_id")
        klass = comment.delete("commentable_type")
        collection = comments

      %w[created_at updated_at].each do |key|
        if comment[key].is_a?(String)
          comment[key] = Time.parse(comment[key])
        end
      end

      if klass == "Question"
        collection = questions;
      end

        collection.update({:_id => id}, "$addToSet" => {:comments => comment})
    end
    begin
      Mongoid.database.collection("answers").drop
    ensure
      begin
        comments.rename("answers")
      rescue
        puts "comments collection doesn't exists"
      ensure
        Answer.override({}, {:_type => "Answer"})
      end
    end

    answers_coll = Mongoid.database.collection("answers")
    answers_coll.find().each do |answer|
      %w[created_at updated_at].each do |key|
        if answer[key].is_a?(String)
          answer[key] = Time.parse(answer[key])
        end
      end
      answers_coll.save(answer)
    end

    puts "updated comments"
  end

  task :groups => [:environment] do
    Group.all(:conditions => {:language.in => [nil, '', 'none']}).each do |group|
      lang = group.description.to_s.language
      puts "Updating #{group.name} subdomain='#{group.subdomain}' detected as: #{lang}"

      group.language = (lang == :spanish) ? 'es' : 'en'
      group.languages = DEFAULT_USER_LANGUAGES
      if group.valid?
        group.save
      else
        puts "Invalid group: #{group.errors.full_messages}"
      end
    end
  end

  task :relocate => [:environment] do
    doc = JSON.parse(File.read('data/countries.json'))
    i=0
    Question.override({:address => nil}, :address => {})
    Answer.override({:address => nil}, :address => {})
    User.override({:address => nil}, :address => {})
    doc.keys.each do |key|
      User.all(:conditions => { :country_name => key}).each do |u|
        p "#{u.login}: before: #{u.country_name}, after: #{doc[key]["address"]["country"]}"
        lat = doc[key]["lat"]
        lon = doc[key]["lon"]
        User.override({:_id => u.id},
                    {:position => {lat: lat, long: lon},
                      :address => doc[key]["address"] || {}})
#         FIXME
#         Comment.override({:user_id => u.id},
#                     {:position => GeoPosition.new(lat, lon),
#                       :address => doc[key]["address"]})
        Question.override({:user_id => u.id},
                    {:position => {lat: lat, long: lon},
                      :address => doc[key]["address"] || {}})
        Answer.override({:user_id => u.id},
                    {:position => {lat: lat, long: lon},
                      :address => doc[key]["address"] || {}})
      end
    end
  end

  task :widgets => [:environment] do
    c=Group.count
    Group.unset({}, {:widgets => true, :question_widgets => true, :welcome_widgets => true, :mainlist_widgets => true})
    i=0
    Group.all.each do |g|
      [SharingButtonsWidget, ModInfoWidget, QuestionBadgesWidget,
       QuestionStatsWidget, QuestionTagsWidget, RelatedQuestionsWidget,
       TagListWidget, CurrentTagsWidget].each do |w|
        g.question_widgets << w.new
      end

      [BadgesWidget, PagesWidget, TopGroupsWidget, TopUsersWidget, TagCloudWidget].each do |w|
        g.welcome_widgets << w.new
        g.mainlist_widgets << w.new
      end

      g.save
      p "(#{i+=1}/#{c}) Updated widgets for group #{g.name}"
    end
  end
end
