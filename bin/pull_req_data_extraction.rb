#!/usr/bin/env ruby
#
# (c) 2012 -- 2015 Georgios Gousios <gousiosg@gmail.com>
#
# BSD licensed, see LICENSE in top level dir
#

require 'time'
require 'linguist'
require 'thread'
require 'rugged'
require 'parallel'
require 'mongo'
require 'travis'
require 'json'
require 'sequel'
require 'trollop'

require 'java'
require 'ruby'
require 'scala'
require 'c'
require 'javascript'
require 'python'

class PullReqDataExtraction

  include Mongo

  class << self
    def run(args = ARGV)
      attr_accessor :options, :args, :name, :config

      command = new()
      command.name = self.class.name
      command.args = args

      command.process_options
      command.validate

      command.config = YAML::load_file command.options[:config]

      if command.options[:travis]
        STDERR.puts "Getting Travis build info for #{ARGV[0] + '/' + ARGV[1]} "
        command.get_travis(ARGV[0] + '/' + ARGV[1])
        return
      end

      command.go
    end
  end

  def process_options
    command = self
    @options = Trollop::options do
      banner <<-BANNER
Extract data for pull requests for a given repository

#{File.basename($0)} owner repo lang

      BANNER
      opt :config, 'config.yaml file location', :short => 'c',
          :default => 'config.yaml'
      opt :travis, 'Only run the Travis build retrieval process',
          :short => 't'
    end
  end

  def validate
    if options[:config].nil?
      unless (file_exists?("config.yaml"))
        Trollop::die "No config file in default location (#{Dir.pwd}). You
                        need to specify the #{:config} parameter."
      end
    else
      Trollop::die "Cannot find file #{options[:config]}" \
          unless File.exists?(options[:config])
    end

    Trollop::die 'Three arguments required' unless !args[2].nil?
  end

  def db
    Thread.current[:sql_db] ||= Proc.new do
      Sequel.single_threaded = true
      Sequel.connect(self.config['sql']['url'], :encoding => 'utf8')
    end.call
    Thread.current[:sql_db]
  end

  def mongo
    Thread.current[:mongo_db] ||= Proc.new do
      mongo_db = MongoClient.new(self.config['mongo']['host'], self.config['mongo']['port']).db(self.config['mongo']['db'])
      unless self.config['mongo']['username'].nil?
        mongo_db.authenticate(self.config['mongo']['username'], self.config['mongo']['password'])
      end
      mongo_db
    end.call
    Thread.current[:mongo_db]
  end

  def get_travis(repo)
    save_file = File.join('cache', repo.gsub(/\//, '-') + '.travis.json')
    if File.exists?(save_file)
      builds = File.open(save_file, 'r').read
      JSON.parse(builds, :symbolize_names => true)
    else
      # Get PR build status from Travis
      begin
        repository = Travis::Repository.find(repo)
      rescue Exception => e
        STDERR.puts "Error getting Travis builds for #{repo}: #{e.message}"
        return []
      end

      STDERR.puts "Getting Travis information for #{repo}"
      builds = []
      repository.each_build do |build|
        builds << if build.pull_request?
                    STDERR.write "\rBuild for PR: #{build[:pull_request_number]}"
                    jobs = build.jobs
                    commits = jobs.map { |x| x.commit }
                    jobs.zip(commits).map do |y|
                      {
                          :pull_req => build[:pull_request_number],
                          :status => y[0][:state],
                          :commit => y[1][:sha],
                          :finished_at => y[0][:finished_at].to_s
                      }
                    end
                  end
      end
      builds = builds.select { |x| !x.nil? }.flatten
      File.open(save_file, 'w'){|f| f.puts builds.to_json}
      builds
    end
  end

  def travis
    @travis_builds ||= (Proc.new {get_travis(ARGV[0] + '/' + ARGV[1])}).call
    @travis_builds
  end

  def repo
    Thread.current[:repo] ||= clone(ARGV[0], ARGV[1])
    Thread.current[:repo]
  end

  def threads
    @threads ||= 1
    @threads
  end

  # Read a source file from the repo and strip its comments
  # The argument f is the result of Grit.lstree
  # Memoizes result per f
  def semaphore
    @semaphore ||= Mutex.new
    @semaphore
  end

  def stripped(f)
    @stripped ||= Hash.new
    unless @stripped.has_key? f
      semaphore.synchronize do
        unless @stripped.has_key? f
          @stripped[f] = strip_comments(repo.read(f[:oid]).data)
        end
      end
    end
    @stripped[f]
  end

  # Main command code
  def go
    interrupted = false

    trap('INT') {
      STDERR.puts "#{File.basename($0)}(#{Process.pid}): Received SIGINT, exiting"
      interrupted = true
    }

    # Init the semaphore
    semaphore

    user_entry = db[:users].first(:login => ARGV[0])

    if user_entry.nil?
      Trollop::die "Cannot find user #{ARGV[0]}"
    end

    repo_entry = db.from(:projects, :users).\
                  where(:users__id => :projects__owner_id).\
                  where(:users__login => ARGV[0]).\
                  where(:projects__name => ARGV[1]).select(:projects__id).first

    if repo_entry.nil?
      Trollop::die "Cannot find repository #{ARGV[0]}/#{ARGV[1]}"
    end

    case ARGV[2]
      when /ruby/i then self.extend(RubyData)
      when /java/i then self.extend(JavaData)
      when /scala/i then self.extend(ScalaData)
      when /javascript/i then self.extend(JavascriptData)
      when /c/i then self.extend(CData)
      when /python/i then self.extend(PythonData)
    end

    # Update the repo
    clone(ARGV[0], ARGV[1], true)

    unless ARGV[3].nil?
      @threads = ARGV[3].to_i
    end

    walker = Rugged::Walker.new(repo)
    walker.sorting(Rugged::SORT_DATE)
    walker.push(repo.head.target)
    @all_commits = walker.map do |commit|
      commit.oid[0..10]
    end

    # Get commits that close issues/pull requests
    # Index them by issue/pullreq id, as a sha might close multiple issues
    # see: https://help.github.com/articles/closing-issues-via-commit-messages
    q = <<-QUERY
    select c.sha
    from commits c, project_commits pc
    where pc.project_id = ?
    and pc.commit_id = c.id
    QUERY

    fixre = /(?:fixe[sd]?|close[sd]?|resolve[sd]?)(?:[^\/]*?|and)#([0-9]+)/mi

    STDERR.puts 'Calculating PRs closed by commits:'
    @closed_by_commit ={}
    commits_in_prs = db.fetch(q, repo_entry[:id]).all
    @closed_by_commit =
        Parallel.map(commits_in_prs, :in_threads => threads) do |x|
          sha = x[:sha]
          result = {}
          mongo['commits'].find({:sha => sha},
                                {:fields => {'commit.message' => 1, '_id' => 0}}).map do |x|
            STDERR.write "\r #{sha}"
            comment = x['commit']['message']

            comment.match(fixre) do |m|
              (1..(m.size - 1)).map do |y|
                result[m[y].to_i] = sha
              end
            end
          end
          result
        end.select{|x| !x.empty?}.reduce({}){|acc, x| acc.merge(x)}

    @prs = pull_reqs(repo_entry)

    STDERR.puts "\nCalculating close reason"
    @close_reason = {}
    @close_reason = @prs.reduce({}) do |acc, pr|
      merged = !pr[:merged_at].nil?
      git_merged = false
      merge_reason = :github

      if not merged
        git_merged, merge_reason = merged_with_git?(pr)
      end

      acc[pr[:github_id]] = [git_merged, merge_reason]
      acc
    end

    STDERR.write "Calculating mergers\n"
    @close_reason = @prs.reduce(@close_reason) do |acc, pr|
      merge_person = merger(pr)
      acc[pr[:github_id]] << merge_person unless merge_person.nil?
      acc
    end

    # Init travis data
    travis

    # Process pull request list
    do_pr = Proc.new do |pr|
      begin
        r = process_pull_request(pr, ARGV[2].downcase)
        if interrupted
          return
        end
        STDERR.puts r
        r
      rescue Exception => e
        STDERR.puts "Error processing pull_request #{pr[:github_id]}: #{e.message}"
        STDERR.puts e.backtrace
        #raise e
      end
    end

    results = Parallel.map(@prs, :in_threads => threads) do |pr|
      do_pr.call(pr)
    end.select { |x| !x.nil? }

    puts results.first.keys.map{|x| x.to_s}.join(',')
    results.sort{|a,b| b[:github_id]<=>a[:github_id]}.each{|x| puts x.values.join(',')}

  end

  # Get a list of pull requests for the processed project
  def pull_reqs(project, github_id = -1)
    q = <<-QUERY
    select u.login as login, p.name as project_name, pr.id, pr.pullreq_id as github_id,
           a.created_at as created_at, b.created_at as closed_at,
			     (select created_at
            from pull_request_history prh1
            where prh1.pull_request_id = pr.id
            and prh1.action='merged' limit 1) as merged_at,
           timestampdiff(minute, a.created_at, b.created_at) as lifetime_minutes,
			timestampdiff(minute, a.created_at, (select created_at
                                           from pull_request_history prh1
                                           where prh1.pull_request_id = pr.id and prh1.action='merged' limit 1)
      ) as mergetime_minutes
    from pull_requests pr, projects p, users u,
         pull_request_history a, pull_request_history b
    where p.id = pr.base_repo_id
	    and a.pull_request_id = pr.id
      and a.pull_request_id = b.pull_request_id
      and a.action='opened' and b.action='closed'
	    and a.created_at < b.created_at
      and p.owner_id = u.id
      and p.id = ?
    QUERY

    if github_id != -1
      q += " and pr.pullreq_id = #{github_id} "
    end
    q += 'group by pr.id order by pr.pullreq_id desc;'

    db.fetch(q, project[:id]).all
  end

  # Process a single pull request
  def process_pull_request(pr, lang)

    # Statistics across pull request commits
    stats = pr_stats(pr)
    merged = !pr[:merged_at].nil?
    git_merged, merge_reason, merge_person = @close_reason[pr[:github_id]]

    # Count number of src/comment lines
    src = src_lines(pr[:id].to_f)

    if src == 0 then raise Exception.new("Bad src lines: 0, pr: #{pr[:github_id]}, id: #{pr[:id]}") end

    months_back = 3
    commits_incl_prs = commits_last_x_months(pr, false, months_back)
    prev_pull_reqs = prev_pull_requests(pr,'opened')

    # Create line for a pull request
    {
        :pull_req_id              => pr[:id],
        :project_name             => "#{pr[:login]}/#{pr[:project_name]}",
        :lang                     => lang,
        :github_id                => pr[:github_id],
        :created_at               => Time.at(pr[:created_at]).to_i,
        :merged_at                => merge_time(pr, merged, git_merged),
        :closed_at                => Time.at(pr[:closed_at]).to_i,
        :lifetime_minutes         => pr[:lifetime_minutes],
        :mergetime_minutes        => merge_time_minutes(pr, merged, git_merged),
        :merged_using             => merge_reason.to_s,
        :conflict                 => conflict?(pr),
        :forward_links            => forward_links?(pr),
        :team_size                => team_size_at_open(pr, months_back),
        :num_commits              => num_commits(pr),
        :num_pr_comments          => num_pr_comments(pr),
        :num_issue_comments       => num_issue_comments(pr),
        :num_commit_comments      => num_commit_comments(pr),
        :num_comments             => num_pr_comments(pr) + num_issue_comments(pr) + num_commit_comments(pr),
        :num_participants         => num_participants(pr),
        :files_added              => stats[:files_added],
        :files_deleted            => stats[:files_removed],
        :files_modified           => stats[:files_modified],
        :files_changed            => stats[:files_added] + stats[:files_modified] + stats[:files_removed],
        :src_files                => stats[:src_files],
        :doc_files                => stats[:doc_files],
        :other_files              => stats[:other_files],
        :perc_external_contribs   => (commits_incl_prs - commits_last_x_months(pr, true, months_back)).to_f / commits_incl_prs,
        :sloc                     => src,
        :src_churn                => stats[:lines_added] + stats[:lines_deleted],
        :test_churn               => stats[:test_lines_added] + stats[:test_lines_deleted],
        :commits_on_files_touched => commits_on_files_touched(pr, months_back),
        :test_lines_per_kloc      => (test_lines(pr[:id]).to_f / src.to_f) * 1000,
        :test_cases_per_kloc      => (num_test_cases(pr[:id]).to_f / src.to_f) * 1000,
        :asserts_per_kloc         => (num_assertions(pr[:id]).to_f / src.to_f) * 1000,
        :watchers                 => watchers(pr),
        :requester                => requester(pr),
        :closer                   => closer(pr),
        :merger                   => merge_person,
        :prev_pullreqs            => prev_pull_reqs,
        :requester_succ_rate      => if prev_pull_reqs > 0 then prev_pull_requests(pr, 'merged').to_f / prev_pull_reqs.to_f else 0 end,
        :followers                => followers(pr),
        :intra_branch             => if intra_branch?(pr) == 1 then true else false end,
        :main_team_member         => main_team_member?(pr, months_back),
        :social_connection_tsay   => social_connection_tsay?(pr),
        :hotness_basilescu        => hotness_basilescu(pr, months_back),
        :team_size_basilescu      => team_size_basilescu(pr, months_back),
        :description_complexity   => description_complexity(pr),
        :workload                 => workload(pr),
        :prior_interaction_issue_events    => prior_interaction_issue_events(pr, months_back),
        :prior_interaction_issue_comments  => prior_interaction_issue_comments(pr, months_back),
        :prior_interaction_pr_events       => prior_interaction_pr_events(pr, months_back),
        :prior_interaction_pr_comments     => prior_interaction_pr_comments(pr, months_back),
        :prior_interaction_commits         => prior_interaction_commits(pr, months_back),
        :prior_interaction_commit_comments => prior_interaction_commit_comments(pr, months_back),
        :first_response           => first_response(pr),
        :ci_latency               => ci_latency(pr),
        :ci_errors                => ci_errors?(pr),
        :ci_test_failures         => ci_test_failures?(pr),
    }
  end

  def merge_time(pr, merged, git_merged)
    if merged
      Time.at(pr[:merged_at]).to_i
    elsif git_merged
      Time.at(pr[:closed_at]).to_i
    else
      ''
    end
  end

  def merge_time_minutes(pr, merged, git_merged)
    if merged
      Time.at(pr[:mergetime_minutes]).to_i
    elsif git_merged
      pr[:lifetime_minutes].to_i
    else
      ''
    end
  end

  # Checks whether a merge of the pull request occurred outside Github
  # This will only discover clean merges; rebases and force-pushes override
  # the commit history, so they are impossible to detect without source code
  # analysis.
  def merged_with_git?(pr)

    #1. Commits from the pull request appear in the master branch
    q = <<-QUERY
	  select c.sha
    from pull_request_commits prc, commits c
	  where prc.commit_id = c.id
		  and prc.pull_request_id = ?
    QUERY
    db.fetch(q, pr[:id]).each do |x|
      unless @all_commits.select { |y| x[:sha].start_with? y }.empty?
        return [true, :commits_in_master]
      end
    end

    #2. The PR was closed by a commit (using the Fixes: convention).
    # Check whether the commit that closes the PR is in the project's
    # master branch
    unless @closed_by_commit[pr[:github_id]].nil?
      sha = @closed_by_commit[pr[:github_id]]
      unless @all_commits.select { |x| sha.start_with? x }.empty?
        return [true, :fixes_in_commit]
      end
    end

    comments = issue_comments(pr[:login], pr[:project_name], pr[:github_id])

    comments.reverse.take(3).map { |x| x['body'] }.uniq.each do |last|
      # 3. Last comment contains a commit number
      last.scan(/([0-9a-f]{6,40})/m).each do |x|
        # Commit is identified as merged
        if last.match(/merg(?:ing|ed)/i) or 
          last.match(/appl(?:ying|ied)/i) or
          last.match(/pull[?:ing|ed]/i) or
          last.match(/push[?:ing|ed]/i) or
          last.match(/integrat[?:ing|ed]/i) 
          return [true, :commit_sha_in_comments]
        else
          # Commit appears in master branch
          unless @all_commits.select { |y| x[0].start_with? y }.empty?
            return [true, :commit_sha_in_comments]
          end
        end
      end

      # 4. Merg[ing|ed] or appl[ing|ed] as last comment of pull request
      if last.match(/merg(?:ing|ed)/i) or 
        last.match(/appl(?:ying|ed)/i) or
        last.match(/pull[?:ing|ed]/i) or
        last.match(/push[?:ing|ed]/i) or
        last.match(/integrat[?:ing|ed]/i) 
        return [true, :merged_in_comments]
      end
    end

    [false, :unknown]
  end

  def conflict?(pr)
    issue_comments(pr[:owner], pr[:project_name], pr[:id]).reduce(false) do |acc, x|
      acc || (not x['body'].match(/conflict/i).nil?)
    end
  end

  def forward_links?(pr)
    owner = pr[:login]
    repo = pr[:project_name]
    pr_id = pr[:github_id]
    issue_comments(owner, repo, pr_id).reduce(false) do |acc, x|
      # Try to find pull_requests numbers referenced in each comment
      a = x['body'].scan(/\#([0-9]+)/m).reduce(false) do |acc1, m|
        if m[0].to_i > pr_id.to_i
          # See if it is a pull request (if not the number is an issue)
          q = <<-QUERY
            select *
            from pull_requests pr, projects p, users u
            where u.id = p.owner_id
              and pr.base_repo_id = p.id
              and u.login = ?
              and p.name = ?
              and pr.pullreq_id = ?
          QUERY
          acc1 || db.fetch(q, owner, repo, m[0]).all.size > 0
        else
          acc1
        end
      end
      acc || a
    end
  end

  # Number of developers that have committed at least once in the interval
  # between the pull request open up to +interval_months+ back
  def team_size_at_open(pr, interval_months)
    q = <<-QUERY
    select count(distinct author_id) as teamsize
    from projects p, commits c, project_commits pc, pull_requests pr,
         pull_request_history prh
    where p.id = pc.project_id
      and pc.commit_id = c.id
      and p.id = pr.base_repo_id
      and prh.pull_request_id = pr.id
      and not exists (select * from pull_request_commits prc1 where prc1.commit_id = c.id)
      and prh.action = 'opened'
      and c.created_at < prh.created_at
      and c.created_at > DATE_SUB(prh.created_at, INTERVAL #{interval_months} MONTH)
      and pr.id=?;
    QUERY
    db.fetch(q, pr[:id]).first[:teamsize]
  end

  # Number of commits in pull request
  def num_commits(pr)
    q = <<-QUERY
    select count(*) as commit_count
    from pull_requests pr, pull_request_commits prc
    where pr.id = prc.pull_request_id
      and pr.id=?
    group by prc.pull_request_id
    QUERY
    db.fetch(q, pr[:id]).first[:commit_count]
  end

  # Number of pull request code review comments in pull request
  def num_pr_comments(pr)
    q = <<-QUERY
    select count(*) as comment_count
    from pull_request_comments prc
    where prc.pull_request_id = ?
    and prc.created_at < (
      select max(created_at)
      from pull_request_history
      where action = 'closed' and pull_request_id = ?)
    QUERY
    db.fetch(q, pr[:id], pr[:id]).first[:comment_count]
  end

  # Number of pull request discussion comments
  def num_issue_comments(pr)
    q = <<-QUERY
    select count(*) as issue_comment_count
    from pull_requests pr, issue_comments ic, issues i
    where ic.issue_id=i.id
    and i.issue_id=pr.pullreq_id
    and pr.base_repo_id = i.repo_id
    and pr.id = ?
    and ic.created_at < (
      select max(created_at)
      from pull_request_history
      where action = 'closed' and pull_request_id = ?)
    QUERY
    db.fetch(q, pr[:id], pr[:id]).first[:issue_comment_count]
  end

  # Number of commit comments on commits composing the pull request
  def num_commit_comments(pr)
    q = <<-QUERY
    select count(*) as commit_comment_count
    from pull_request_commits prc, commit_comments cc
    where prc.commit_id = cc.commit_id
      and prc.pull_request_id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:commit_comment_count]
  end

  def num_participants(pr)
    q = <<-QUERY
    select count(distinct(user_id)) as participants from
      (select user_id
       from pull_request_comments
       where pull_request_id = ?
       union
       select user_id
       from issue_comments ic, issues i
       where i.id = ic.issue_id and i.pull_request_id = ?) as num_participants
    QUERY
    db.fetch(q, pr[:id], pr[:id]).first[:participants]
  end

  # Number of followers of the person that created the pull request
  def followers(pr)
    q = <<-QUERY
    select count(f.follower_id) as num_followers
    from pull_requests pr, followers f, pull_request_history prh
    where prh.actor_id = f.user_id
      and prh.pull_request_id = pr.id
      and prh.action = 'opened'
      and f.created_at < prh.created_at
      and pr.id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:num_followers]
  end

  # Number of project watchers/stargazers at the time the pull request was made
  def watchers(pr)
    q = <<-QUERY
    select count(w.user_id) as num_watchers
    from watchers w, pull_requests pr, pull_request_history prh
    where prh.pull_request_id = pr.id
      and w.created_at < prh.created_at
      and w.repo_id = pr.base_repo_id
      and prh.action='opened'
      and pr.id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:num_watchers]
  end

  # Person that first closed the pull request
  def closer(pr)
    q = <<-QUERY
    select u.login as login
    from issues i, issue_events ie, users u
    where i.pull_request_id = ?
      and ie.issue_id = i.id
      and (ie.action = 'closed' or ie.action = 'merged')
      and u.id = ie.actor_id
    QUERY
    closer = db.fetch(q, pr[:id]).first

    unless closer.nil?
      closer[:login]
    else
      ''
    end
  end

  # Person that first merged the pull request
  def merger(pr)
    q = <<-QUERY
    select u.login as login
    from issues i, issue_events ie, users u
    where i.pull_request_id = ?
      and ie.issue_id = i.id
      and ie.action = 'merged'
      and u.id = ie.actor_id
    QUERY
    merger = db.fetch(q, pr[:id]).first

    if merger.nil?
      # If the PR was merged, then it is safe to assume that the
      # closer is also the merger
      if not @close_reason[pr[:github_id]].nil? and @close_reason[pr[:github_id]][1] != :unknown
        closer(pr)
      else
        ''
      end
    else
      merger[:login]
    end
  end

  # Number of followers of the person that created the pull request
  def requester(pr)
    q = <<-QUERY
    select u.login as login
    from users u, pull_request_history prh
    where prh.actor_id = u.id
      and action = 'opened'
      and prh.pull_request_id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:login]
  end

  # Number of previous pull requests for the pull requester
  def prev_pull_requests(pr, action)

    if action == 'merged'
      q = <<-QUERY
      select pr.pullreq_id, prh.pull_request_id as num_pull_reqs
      from pull_request_history prh, pull_requests pr
      where prh.action = 'opened'
        and prh.created_at < (select min(created_at) from pull_request_history prh1 where prh1.pull_request_id = ? and prh1.action = 'opened')
        and prh.actor_id = (select min(actor_id) from pull_request_history prh1 where prh1.pull_request_id = ? and prh1.action = 'opened')
        and prh.pull_request_id = pr.id
        and pr.base_repo_id = (select pr1.base_repo_id from pull_requests pr1 where pr1.id = ?);
      QUERY

      pull_reqs = db.fetch(q, pr[:id], pr[:id], pr[:id]).all
      pull_reqs.reduce(0) do |acc, pull_req|
        if not @close_reason[pull_req[:pullreq_id]].nil? and @close_reason[pull_req[:pullreq_id]][1] != :unknown
          acc += 1
        end
        acc
      end
    else
      q = <<-QUERY
      select pr.pullreq_id, prh.pull_request_id as num_pull_reqs
      from pull_request_history prh, pull_requests pr
      where prh.action = ?
        and prh.created_at < (select min(created_at) from pull_request_history prh1 where prh1.pull_request_id = ?)
        and prh.actor_id = (select min(actor_id) from pull_request_history prh1 where prh1.pull_request_id = ? and action = ?)
        and prh.pull_request_id = pr.id
        and pr.base_repo_id = (select pr1.base_repo_id from pull_requests pr1 where pr1.id = ?);
      QUERY
      db.fetch(q, action, pr[:id], pr[:id], action, pr[:id]).all.size
    end
  end

  def social_connection_tsay?(pr)
    q = <<-QUERY
    select *
    from followers
    where user_id = (
      select min(prh.actor_id)
      from pull_request_history prh
      where prh.pull_request_id = ?
        and prh.action = 'closed'
        )
    and follower_id = (
      select min(prh.actor_id)
      from pull_request_history prh
      where prh.pull_request_id = ?
        and prh.action = 'opened'
        )
    and created_at < (
      select min(created_at)
        from pull_request_history
        where pull_request_id = ?
        and action = 'opened'
    )
    QUERY
    db.fetch(q, pr[:id], pr[:id], pr[:id]).all.size > 0
  end

  # The number of events before a particular pull request that the user has
  # participated in for this project.
  def prior_interaction_issue_events(pr, months_back)
    q = <<-QUERY
      select count(distinct(i.id)) as num_issue_events
      from issue_events ie, pull_request_history prh, pull_requests pr, issues i
      where ie.actor_id = prh.actor_id
        and i.repo_id = pr.base_repo_id
        and i.id = ie.issue_id
        and prh.pull_request_id = pr.id
        and prh.action = 'opened'
        and ie.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH)
        and ie.created_at < prh.created_at
        and prh.pull_request_id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:num_issue_events]
  end

  def prior_interaction_issue_comments(pr, months_back)
    q = <<-QUERY
    select count(distinct(ic.comment_id)) as issue_comment_count
    from pull_request_history prh, pull_requests pr, issues i, issue_comments ic
    where ic.user_id = prh.actor_id
      and i.repo_id = pr.base_repo_id
      and i.id = ic.issue_id
      and prh.pull_request_id = pr.id
      and prh.action = 'opened'
      and ic.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH)
      and ic.created_at < prh.created_at
      and prh.pull_request_id = ?;
    QUERY
    db.fetch(q, pr[:id]).first[:issue_comment_count]
  end

  def prior_interaction_pr_events(pr, months_back)
    q = <<-QUERY
    select count(distinct(prh1.id)) as count_pr
    from  pull_request_history prh1, pull_request_history prh, pull_requests pr1, pull_requests pr
    where prh1.actor_id = prh.actor_id
      and pr1.base_repo_id = pr.base_repo_id
      and pr1.id = prh1.pull_request_id
      and pr.id = prh.pull_request_id
      and prh.action = 'opened'
      and prh1.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH)
      and prh1.created_at < prh.created_at
      and prh.pull_request_id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:count_pr]
  end

  def prior_interaction_pr_comments(pr, months_back)
    q = <<-QUERY
    select count(prc.comment_id) as count_pr_comments
    from pull_request_history prh, pull_requests pr1, pull_requests pr, pull_request_comments prc
    where prh.actor_id = prc.user_id
      and pr1.base_repo_id = pr.base_repo_id
      and pr1.id = prh.pull_request_id
      and pr.id = prc.pull_request_id
      and prh.action = 'opened'
      and prc.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH)
      and prc.created_at < prh.created_at
      and prh.pull_request_id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:count_pr_comments]
  end

  def prior_interaction_commits(pr, months_back)
    q = <<-QUERY
    select count(distinct(c.id)) as count_commits
    from pull_request_history prh, pull_requests pr, commits c, project_commits pc
    where (c.author_id = prh.actor_id or c.committer_id = prh.actor_id)
      and pc.project_id = pr.base_repo_id
      and c.id = pc.commit_id
      and prh.pull_request_id = pr.id
      and prh.action = 'opened'
      and c.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH)
      and c.created_at < prh.created_at
      and prh.pull_request_id = ?;
    QUERY
    db.fetch(q, pr[:id]).first[:count_commits]
  end

  def prior_interaction_commit_comments(pr, months_back)
    q = <<-QUERY
    select count(distinct(cc.id)) as count_commits
    from pull_request_history prh, pull_requests pr, commits c, project_commits pc, commit_comments cc
    where cc.commit_id = c.id
      and cc.user_id = prh.actor_id
      and pc.project_id = pr.base_repo_id
      and c.id = pc.commit_id
      and prh.pull_request_id = pr.id
      and prh.action = 'opened'
      and cc.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH)
      and cc.created_at < prh.created_at
      and prh.pull_request_id = ?;

    QUERY
    db.fetch(q, pr[:id]).first[:count_commits]
  end

  # Median number of commits to files touched by the pull request relative to
  # all project commits during the last three months
  def hotness_basilescu(pr_id, months_back)
    commits_on_files_touched(pr_id, months_back).to_f / commits_last_x_months(pr_id, false, months_back).to_f
  end

  # People that committed (not through pull requests) up to months_back
  # from the time the PR was created.
  def committer_team(pr, months_back)
    q = <<-QUERY
    select distinct(u.login)
    from commits c, project_commits pc, pull_requests pr, users u, pull_request_history prh
    where pr.base_repo_id = pc.project_id
      and not exists (select * from pull_request_commits where commit_id = c.id)
      and pc.commit_id = c.id
      and pr.id = ?
      and u.id = c.committer_id
      and u.fake is false
      and prh.pull_request_id = pr.id
      and prh.action = 'opened'
      and c.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH);
    QUERY
    db.fetch(q, pr[:id]).all
  end

  # People that merged (not through pull requests) up to months_back
  # from the time the PR was created.
  def merger_team(pr, months_back)
    @close_reason.map do |k,v|
      created_at = @prs.find{|x| x[:github_id] == k}
      [created_at[:created_at], v[2]]
    end.find_all do |x|
      x[0].to_i > (pr[:created_at].to_i  - months_back * 30 * 24 * 3600)
    end.map do |x|
      x[1]
    end.select{|x| x != ''}.uniq
  end

  # Number of integrators active during x months prior to pull request
  # creation.
  def team_size_basilescu(pr, months_back)
    (committer_team(pr, months_back) + merger_team(pr, months_back)).uniq.size
  end

  def social_distance_basilescu(pr_id)

  end

  def availability(pr_id)

  end

  # Time interval in minutes from pull request creation to first response
  # by reviewers
  def first_response(pr)
    q = <<-QUERY
      select min(created) as first_resp from (
        select min(prc.created_at) as created
        from pull_request_comments prc, users u
        where prc.pull_request_id = ?
          and u.id = prc.user_id
          and u.login not in ('travis-ci', 'cloudbees')
        union
        select min(ic.created_at) as created
        from issues i, issue_comments ic, users u
        where i.pull_request_id = ?
          and i.id = ic.issue_id
          and u.id = ic.user_id
          and u.login not in ('travis-ci', 'cloudbees')
      ) as a;
    QUERY
    resp = db.fetch(q, pr[:id], pr[:id]).first[:first_resp]
    unless resp.nil?
      (resp - pr[:created_at]).to_i / 60
    else
      -1
    end
  end

  # Time between PR arrival and last CI run
  def ci_latency(pr)
    last_run = travis.find_all{|b| b[:pull_req] == pr[:github_id]}.sort_by { |x| Time.parse(x[:finished_at]).to_i }[-1]
    unless last_run.nil?
      Time.parse(last_run[:finished_at]) - pr[:created_at]
    else
      -1
    end
  end

  # Did the build result in errors?
  def ci_errors?(pr)
    not travis.find_all{|b| b[:pull_req] == pr[:github_id] and b[:status] == 'errored'}.empty?
  end

  # Did the build result in test failuers?
  def ci_test_failures?(pr)
    not travis.find_all{|b| b[:pull_req] == pr[:github_id] and b[:status] == 'failed'}.empty?
  end

  # Total number of words in the pull request title and description
  def description_complexity(pr)
    pull_req = pull_req_entry(pr[:id])
    (pull_req['title'] + ' ' + pull_req['body']).gsub(/[\n\r]\s+/, ' ').split(/\s+/).size
  end

  # Total number of pull requests still open in each project at pull
  # request creation time.
  def workload(pr)
    q = <<-QUERY
    select count(distinct(prh.pull_request_id)) as num_open
    from pull_request_history prh, pull_requests pr, pull_request_history prh3
    where prh.created_at <  prh3.created_at
    and prh.action = 'opened'
    and pr.id = prh.pull_request_id
    and prh3.pull_request_id = ?
    and (exists (select * from pull_request_history prh1
                where prh1.action = 'closed'
          and prh1.pull_request_id = prh.pull_request_id
          and prh1.created_at > prh3.created_at)
      or not exists (select * from pull_request_history prh1
               where prh1.action = 'closed'
               and prh1.pull_request_id = prh.pull_request_id)
    )
    and pr.base_repo_id = (select pr3.base_repo_id from pull_requests pr3 where pr3.id = ?)
    QUERY
    db.fetch(q, pr[:id], pr[:id]).first[:num_open]
  end

  # Check if the pull request is intra_branch
  def intra_branch?(pr)
    q = <<-QUERY
    select IF(base_repo_id = head_repo_id, true, false) as intra_branch
    from pull_requests where id = ?
    QUERY
    db.fetch(q, pr[:id]).first[:intra_branch]
  end

  # Check if the requester is part of the project's main team
  def main_team_member?(pr, months_back)
    (committer_team(pr, months_back) + merger_team(pr, months_back)).uniq.include? requester(pr)
  end

  # Various statistics for the pull request. Returned as Hash with the following
  # keys: :lines_added, :lines_deleted, :files_added, :files_removed,
  # :files_modified, :files_touched, :src_files, :doc_files, :other_files.
  def pr_stats(pr)
    pr_id = pr[:id]
    raw_commits = commit_entries(pr_id)
    result = Hash.new(0)

    def file_count(commits, status)
      commits.map do |c|
        c['files'].reduce(Array.new) do |acc, y|
          if y['status'] == status then acc << y['filename'] else acc end
        end
      end.flatten.uniq.size
    end

    def files_touched(commits)
      commits.map do |c|
        c['files'].map do |y|
          y['filename']
        end
      end.flatten.uniq.size
    end

    def file_type(f)
      lang = Linguist::Language.find_by_filename(f)
      if lang.empty? then :data else lang[0].type end
    end

    def file_type_count(commits, type)
      commits.map do |c|
        c['files'].reduce(Array.new) do |acc, y|
          if file_type(y['filename']) == type then acc << y['filename'] else acc end
        end
      end.flatten.uniq.size
    end

    def lines(commit, type, action)
      commit['files'].select do |x|
        next unless file_type(x['filename']) == :programming

        case type
          when :test
            true if test_file_filter.call(x['filename'])
          when :src
            true unless test_file_filter.call(x['filename'])
          else
            false
        end
      end.reduce(0) do |acc, y|
        diff_start = case action
                       when :added
                         "+"
                       when :deleted
                         "-"
                     end

        acc += unless y['patch'].nil?
                 y['patch'].lines.select{|x| x.start_with?(diff_start)}.size
               else
                 0
               end
        acc
      end
    end

    raw_commits.each{ |x|
      next if x.nil?
      result[:lines_added] += lines(x, :src, :added)
      result[:lines_deleted] += lines(x, :src, :deleted)
      result[:test_lines_added] += lines(x, :test, :added)
      result[:test_lines_deleted] += lines(x, :test, :deleted)
    }

    result[:files_added] += file_count(raw_commits, "added")
    result[:files_removed] += file_count(raw_commits, "removed")
    result[:files_modified] += file_count(raw_commits, "modified")
    result[:files_touched] += files_touched(raw_commits)

    result[:src_files] += file_type_count(raw_commits, :programming)
    result[:doc_files] += file_type_count(raw_commits, :markup)
    result[:other_files] += file_type_count(raw_commits, :data)

    result
  end

  # Number of commits on the files changed by the pull request
  # between the time the PR was created and `months_back`
  # excluding those created by the PR
  def commits_on_files_touched(pr, months_back)
    oldest = Time.at(Time.at(pr[:created_at]).to_i - 3600 * 24 * 30 * months_back)
    pr_against = pull_req_entry(pr[:id])['base']['sha']
    commits = commit_entries(pr[:id])

    commits_per_file = commits.flat_map { |c|
      c['files'].map { |f|
        [c['sha'], f['filename']]
      }
    }.group_by {|c|
      c[1]
    }

    commits_per_file.keys.map do |filename|
      commits_in_pr = commits_per_file[filename].map{|x| x[0]}

      walker = Rugged::Walker.new(repo)
      walker.sorting(Rugged::SORT_DATE)
      walker.push(pr_against)

      num_commits = walker.take_while do |c|
        c.time > oldest
      end.reduce(0) do |acc, c|
        if c.diff(paths: [filename.to_s]).size > 0 and
            not commits_in_pr.include? c.oid
          acc += 1
        end
        acc
      end
      num_commits
    end.reduce(0) { |acc, x| acc + x }
  end

  # Total number of commits on the project in the period up to `months` before
  # the pull request was opened. `exclude_pull_req` controls whether commits
  # from pull requests should be accounted for.
  def commits_last_x_months(pr, exclude_pull_req, months_back)
    q = <<-QUERY
    select count(c.id) as num_commits
    from projects p, commits c, project_commits pc, pull_requests pr,
         pull_request_history prh
    where p.id = pc.project_id
      and pc.commit_id = c.id
      and p.id = pr.base_repo_id
      and prh.pull_request_id = pr.id
      and prh.action = 'opened'
      and c.created_at < prh.created_at
      and c.created_at > DATE_SUB(prh.created_at, INTERVAL #{months_back} MONTH)
      and pr.id=?
    QUERY

    if exclude_pull_req
      q << ' and not exists (select * from pull_request_commits prc1 where prc1.commit_id = c.id)'
    end

    db.fetch(q, pr[:id]).first[:num_commits]
  end

  private

  def pull_req_entry(pr_id)
    q = <<-QUERY
    select u.login as user, p.name as name, pr.pullreq_id as pullreq_id
    from pull_requests pr, projects p, users u
    where pr.id = ?
    and pr.base_repo_id = p.id
    and u.id = p.owner_id
    QUERY
    pullreq = db.fetch(q, pr_id).all[0]

    mongo['pull_requests'].find_one({:owner => pullreq[:user],
                                     :repo => pullreq[:name],
                                     :number => pullreq[:pullreq_id]})
  end

  # JSON objects for the commits included in the pull request
  def commit_entries(pr_id)
    q = <<-QUERY
    select c.sha as sha
    from pull_requests pr, pull_request_commits prc, commits c
    where pr.id = prc.pull_request_id
    and prc.commit_id = c.id
    and pr.id = ?
    QUERY
    commits = db.fetch(q, pr_id).all

    commits.reduce([]){ |acc, x|
      a = mongo['commits'].find_one({:sha => x[:sha]})
      acc << a unless a.nil?
      acc
    }.select{|c| c['parents'].size <= 1}
  end

  # List of files in a project checkout. Filter is an optional binary function
  # that takes a file entry and decides whether to include it in the result.
  def files_at_commit(pr_id, filter = lambda{true})
    q = <<-QUERY
    select c.sha
    from pull_requests p, commits c
    where c.id = p.base_commit_id
    and p.id = ?
    QUERY

    def lslr(tree, path = '')
      all_files = []
      for f in tree.map{|x| x}
        f[:path] = path + '/' + f[:name]
        if f[:type] == :tree
          begin
            all_files << lslr(repo.lookup(f[:oid]), f[:path])
          rescue Exception => e
            STDERR.puts e
            all_files
          end
        else
          all_files << f
        end
      end
      all_files.flatten
    end

    base_commit = db.fetch(q, pr_id).all[0][:sha]
    begin
      files = lslr(repo.lookup(base_commit).tree)
      files.select{|x| filter.call(x)}
    rescue Exception => e
      STDERR.puts "Cannot find commit #{base_commit} in base repo"
      []
    end
  end

  # Returns all comments for the issue sorted by creation date ascending
  def issue_comments(owner, repo, pr_id)
    Thread.current[:issue_id] ||= pr_id

    if pr_id != Thread.current[:issue_id]
      Thread.current[:issue_id] = pr_id
      Thread.current[:issue_cmnt] = nil
    end

    Thread.current[:issue_cmnt] ||= Proc.new {
      issue_comments = mongo['issue_comments']
      ic = issue_comments.find(
          {'owner' => owner, 'repo' => repo, 'issue_id' => pr_id.to_i},
          {:fields => {'body' => 1, 'created_at' => 1, '_id' => 0},
           :sort => {'created_at' => :asc}}
      ).map {|x| x}

    }.call
    Thread.current[:issue_cmnt]
  end

  def count_lines(files, include_filter = lambda{|x| true})
    files.map{ |f|
      stripped(f).lines.select{|x|
        not x.strip.empty?
      }.select{ |x|
        include_filter.call(x)
      }.size
    }.reduce(0){|acc,x| acc + x}
  end

  # Clone or update, if already cloned, a git repository
  def clone(user, repo, update = false)

    def spawn(cmd)
      proc = IO.popen(cmd, 'r')

      proc_out = Thread.new {
        while !proc.eof
          STDERR.puts "#{proc.gets}"
        end
      }

      proc_out.join
    end

    checkout_dir = File.join('cache', user, repo)

    begin
      repo = Rugged::Repository.new(checkout_dir)
      if update
        spawn("cd #{checkout_dir} && git pull")
      end
      repo
    rescue
      spawn("git clone git://github.com/#{user}/#{repo}.git #{checkout_dir}")
      Rugged::Repository.new(checkout_dir)
    end
  end

  # [buff] is an array of file lines, with empty lines stripped
  # [regexp] is a regexp or an array of regexps to match multiline comments
  def count_multiline_comments(buff, regexp)
    unless regexp.is_a?(Array) then regexp = [regexp] end

    regexp.reduce(0) do |acc, regexp|
      acc + buff.reduce(''){|acc,x| acc + x}.scan(regexp).map { |x|
        x.map{|y| y.lines.count}.reduce(0){|acc,y| acc + y}
      }.reduce(0){|acc, x| acc + x}
    end
  end

  # [buff] is an array of file lines, with empty lines stripped
  def count_single_line_comments(buff, comment_regexp)
    a = buff.select { |l|
      not l.match(comment_regexp).nil?
    }.size
    a
  end

  def src_files(pr_id)
    raise Exception.new("Unimplemented")
  end

  def src_lines(pr_id)
    raise Exception.new("Unimplemented")
  end

  def test_files(pr_id)
    raise Exception.new("Unimplemented")
  end

  def test_lines(pr_id)
    raise Exception.new("Unimplemented")
  end

  def num_test_cases(pr_id)
    raise Exception.new("Unimplemented")
  end

  def num_assertions(pr_id)
    raise Exception.new("Unimplemented")
  end

  # Return a function filename -> Boolean, that determines whether a
  # filename is a test file
  def test_file_filter
    raise Exception.new("Unimplemented")
  end

  def strip_comments(buff)
    raise Exception.new("Unimplemented")
  end

end

PullReqDataExtraction.run
#vim: set filetype=ruby expandtab tabstop=2 shiftwidth=2 autoindent smartindent:
