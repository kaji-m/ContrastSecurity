# MIT License
# Copyright (c) 2020 Contrast Security Japan G.K.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
class ContrastController < ApplicationController
  before_action :require_login
  skip_before_filter :verify_authenticity_token
  accept_api_auth :vote

  CUSTOM_FIELDS = ['contrast_org_id', 'contrast_app_id', 'contrast_vul_id', 'contrast_lib_id'].freeze

  def vote
    #logger.info(request.body.read)
    t_issue = JSON.parse(request.body.read)
    #logger.info(t_issue['description'])
    project_identifier = t_issue['project']
    tracker_str = t_issue['tracker']
    project = Project.find_by_identifier(project_identifier)
    tracker = Tracker.find_by_name(tracker_str)
    priority = IssuePriority.default
    if t_issue.has_key?('priority')
      priority_str = t_issue['priority'].gsub(/\\u([\da-fA-F]{4})/){[$1].pack('H*').unpack('n*').pack('U*')}
      priority = IssuePriority.find_by_name(priority_str)
    end
    #logger.info(priority)
    if project.nil? || tracker.nil? || priority.nil?
      return head :not_found
    end
    vul_pattern = /index.html#\/(.+)\/applications\/(.+)\/vulns\/(.+)\) was found in/
    lib_pattern = /.+ was found in ([^(]+) \(.+index.html#\/(.+)\/.+\/(.+)\/([^)]+)\),.+\/applications\/([^)]+)\)./
    is_vul = t_issue['description'].match(vul_pattern)
    is_lib = t_issue['description'].match(lib_pattern)
    if is_vul
      if not Setting.plugin_contrastsecurity['vul_issues']
        return render plain: 'Vul Skip'
      end
      org_id = is_vul[1]
      app_id = is_vul[2]
      vul_id = is_vul[3]
      lib_id = ''
      # /Contrast/api/ng/[ORG_ID]/traces/[APP_ID]/trace/[VUL_ID]
      teamserver_url = Setting.plugin_contrastsecurity['teamserver_url']
      url = sprintf('%s/api/ng/%s/traces/%s/trace/%s', teamserver_url, org_id, app_id, vul_id)
      #logger.info(url)
      get_data = callAPI(url)
      vuln_json = JSON.parse(get_data)
      summary = vuln_json['trace']['title']
      story_url = ''
      howtofix_url = ''
      self_url = ''
      vuln_json['trace']['links'].each do |c_link|
        if c_link['rel'] == 'self'
          self_url = c_link['href']
        end
        if c_link['rel'] == 'story'
          story_url = c_link['href']
        end
        if c_link['rel'] == 'recommendation'
          howtofix_url = c_link['href']
        end
      end
      #logger.info(summary)
      #logger.info(story_url)
      #logger.info(howtofix_url)
      #logger.info(self_url)
      # Story
      get_story_data = callAPI(story_url)
      story_json = JSON.parse(get_story_data)
      story = story_json['story']['risk']['text']
      # How to fix
      get_howtofix_data = callAPI(howtofix_url)
      howtofix_json = JSON.parse(get_howtofix_data)
      howtofix = howtofix_json['recommendation']['text']
      # description
      description = ""
      description << l(:report_vul_overview) + "\n"
      description << story + "\n\n"
      description << l(:report_vul_howtofix) + "\n"
      description << howtofix + "\n\n"
      description << l(:report_vul_url) + "\n"
      description << self_url
    elsif is_lib
      if not Setting.plugin_contrastsecurity['lib_issues']
        return render plain: 'Lib Skip'
      end
      lib_name = is_lib[1]
      org_id = is_lib[2]
      app_id = is_lib[5]
      vul_id = ''
      lang = is_lib[3]
      lib_id = is_lib[4]
      teamserver_url = Setting.plugin_contrastsecurity['teamserver_url']
      url = sprintf('%s/api/ng/%s/libraries/%s/%s?expand=vulns', teamserver_url, org_id, lang, lib_id)
      get_data = callAPI(url)
      lib_json = JSON.parse(get_data)
      file_version = lib_json['library']['file_version']
      latest_version = lib_json['library']['latest_version']
      classes_used = lib_json['library']['classes_used']
      class_count = lib_json['library']['class_count']
      cve_list = Array.new
      lib_json['library']['vulns'].each do |c_link|
        cve_list.push(c_link['name'])
      end
      liburl_pattern = /.+ was found in .+\((.+)\),.+/
      is_liburl = t_issue['description'].match(liburl_pattern)
      self_url = ''
      if is_liburl
        self_url = is_liburl[1]
      end
      summary = lib_name
      description = ""
      description << l(:report_lib_curver) + "\n"
      description << file_version + "\n\n"
      description << l(:report_lib_newver) + "\n"
      description << latest_version + "\n\n"
      description << l(:report_lib_class) + "\n"
      description << classes_used.to_s + "/" + class_count.to_s + "\n\n"
      description << l(:report_lib_cves) + "\n"
      description << cve_list.join("\n") + "\n\n"
      description << l(:report_lib_url) + "\n"
      description << self_url
    else
      return render plain: 'Test URL Success'
    end
    custom_field_hash = {}
    CUSTOM_FIELDS.each do |custom_field_name|
      custom_field = IssueCustomField.find_by_name(custom_field_name)
      if custom_field.nil?
        custom_field = IssueCustomField.new(name: custom_field_name)
        custom_field.position = 1
        custom_field.visible = true
        custom_field.is_required = false
        custom_field.is_filter = false
        custom_field.searchable = false
        custom_field.field_format = 'string'
        custom_field.projects << project
        custom_field.trackers << tracker
        custom_field.save
      end
      custom_field_hash[custom_field_name] = custom_field.id
    end
    issue = Issue.new(
      project: project,
      subject: summary,
      tracker: tracker,
      priority: priority,
      description: description,
      custom_fields: [
        {'id': custom_field_hash['contrast_org_id'], 'value': org_id},
        {'id': custom_field_hash['contrast_app_id'], 'value': app_id},
        {'id': custom_field_hash['contrast_vul_id'], 'value': vul_id},
        {'id': custom_field_hash['contrast_lib_id'], 'value': lib_id}
      ],
      author: User.current
    )
    if issue.save
      logger.info('[Contrast plugin] Issue has been reported.')
      return head :ok
    else
      logger.error('[Contrast plugin] Issue creation failed.')
      return head :internal_server_error
    end
  end

  def callAPI(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    req = Net::HTTP::Get.new(uri.request_uri)
    req["Authorization"] = Setting.plugin_contrastsecurity['auth_header']
    req["API-Key"] = Setting.plugin_contrastsecurity['api_key']
    req['Content-Type'] = req['Accept'] = 'application/json'
    res = http.request(req)
    return res.body
  end
end

