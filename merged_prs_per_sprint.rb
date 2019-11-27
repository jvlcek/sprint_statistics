require_relative 'sprint_statistics'
require_relative 'milestone'
require 'yaml'

@config = YAML.load_file('config.yaml')

def github_api_token
  @github_api_token ||= ENV["GITHUB_API_TOKEN"]
end

def stats
  @stats ||= SprintStatistics.new(github_api_token)
end

def priorities
  @priorities ||= begin
    @config.dig(:priority).tap do |priority|
      priority.each_with_index { |p, idx| p[:index] = idx }
    end
  end
end

def user_filters
  @user_filters ||= (@config.dig(:filters, :users) || []).map(&:downcase)
end

def label_filters
  @label_filters ||= @config.dig(:filters, :labels) || []
end

def repos_to_track
  organization = @config[:github_organization]
  puts "Loading Organization: #{organization}"

  repos = stats.project_names_from_org(organization).to_a + @config[:additional_repos].to_a
  repos - @config[:excluded_repos].to_a
end

def filters_match?(pr)
  return true if user_filters.include?(pr.user.login.downcase)
  return true unless (label_filters & pr.labels.collect(&:name)).blank?

  false
end

def filter_repo_prs?(fq_repo_name)
  return false if user_filters.blank? && label_filters.blank?

  !@config.dig(:filters, :non_filtered_repos).include?(fq_repo_name)
end

def prioritize_prs(prs)
  prs.each do |pr|
    priority = priorities.detect { |p| pr.label_names.include?(p[:label]) }
    pr.priority, pr.category = if priority
                                 [priority[:index], priority[:prefix]]
                               else
                                 [priorities.count, '']
                               end
  end.sort_by(&:priority)
end

def title_markdown(pr)
  "[#{pr.title} (##{pr.number})](#{pr.pull_request.html_url})"
end

def milestone_prs(milestone, milestone_range, fq_repo_name)
  params = {:state => "closed", :sort => 'closed_at', :direction => 'desc'}

  prs =
    if milestone
      stats.pull_requests(fq_repo_name, params.merge(:milestone => milestone.number))
    else
      since = milestone_range.begin.in_time_zone("US/Pacific").iso8601
      stats.pull_requests(fq_repo_name, params.merge(:since => since)).select do |pr|
        milestone_range.include?(pr.updated_at.to_date)
      end
    end

  prs.each { |pr| pr.label_names = pr.labels.collect(&:name) }
  prs
end

def write_stdout_and_file(f, line)
  puts line
  f.puts line + "<br/>"
end

def prs_for_milestone(milestone, milestone_range, fq_repo_name)
  all_prs = milestone_prs(milestone, milestone_range, fq_repo_name)

  if filter_repo_prs?(fq_repo_name)
    prs = all_prs.select { |pr| filters_match?(pr) }
  else
    prs = all_prs
  end

  [prs, all_prs.count]
end

def process_repo(fq_repo_name, milestone_title, milestone_range, f)
  # Each repo has a different milestone number, so we have to lookup by name
  milestone = stats.client.milestones(fq_repo_name, :state => "all").detect { |m| m[:title] == milestone_title }
  prs, total_pr_count = prs_for_milestone(milestone, milestone_range, fq_repo_name)
  return if prs.count.zero?

  write_stdout_and_file(f, '')
  write_stdout_and_file(f, "Repo: #{fq_repo_name}  PR (Selected/Total): (#{prs.count}/#{total_pr_count})")
  prioritize_prs(prs).each { |pr| f.puts "#{pr.category}, #{pr.user.login},#{title_markdown(pr)}<br/>" }
end

def process_repos(milestone_title)
  milestone_range = Milestone.range(milestone_title)

  File.open("merged_prs_for #{milestone_title}.md", 'w') do |f|
    write_stdout_and_file(f, "Milestone Statistics for: \"#{milestone_title}\"  (#{milestone_range})")

    empty_repos = repos_to_track.reject do |fq_repo_name|
      process_repo(fq_repo_name, milestone_title, milestone_range, f)
    end
    puts "Empty Repos: #{empty_repos.count}\nRepo List: #{empty_repos.join(", ")}"
  end
end

def completed_in
  start_time = Time.now
  yield
  puts "Completed in #{Time.now - start_time}"
end

milestone = Milestone.prompt_for_milestone
exit if milestone.nil?
milestone = milestone.title

completed_in { process_repos(milestone) }
