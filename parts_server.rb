# Copyright 2012 Team 254. All Rights Reserved.
# @author pat@patfairbank.com (Patrick Fairbank)
#
# The main class of the parts management web server.

require "active_support/time"
require "cgi"
require "dedent"
require "eventmachine"
require "json"
require "pathological"
require "pony"
require "sinatra/base"
require "fileutils"
require "models"
require "slack-ruby-client"
require "trello"

module CheesyParts
  class Server < Sinatra::Base
    # set :static, false
    def self.run!
    	super do |server|
    	  server.ssl=true
        server.ssl_options = {
                 :cert_chain_file  => File.dirname(__FILE__) + "/fullchain.pem",
                 :private_key_file => File.dirname(__FILE__) + "/privkey.pem",
                 :verify_peer      => false
        }
      end
    end
    use Rack::Session::Cookie, :key => "rack.session", :expire_after => 3600
    before do
      # Enforce authentication for all routes except login and user registration.
      @user = User[session[:user_id]]
      authenticate! unless ["/login", "/register"].include?(request.path)

	  if CheesyCommon::Config.slack_enabled
		  # Initialize slack bot
		  Slack.configure do |config|
		  config.token = CheesyCommon::Config.slack_api_token
		  end
		  $slack_bot = Slack::Web::Client.new
		  $slack_bot.auth_test
	  end
	  if CheesyCommon::Config.trello_enabled
		  # Initialize Trello bot
		  Trello.configure do |config|
		  config.developer_public_key = CheesyCommon::Config.trello_public
		  config.member_token = CheesyCommon::Config.trello_member
	  end
      end
    end

    def authenticate!
      redirect "/login?redirect=#{request.path}" if @user.nil?
      if @user.enabled == 0
        session[:user_id] = nil
        redirect "/login?disabled=1"
      end
    end

    def require_permission(user_permitted)
      halt(400, "Insufficient permissions.") unless user_permitted
    end

    # Helper function to send an e-mail through Gmail's SMTP server.
    def send_email(to, subject, body)
      # Run this asynchronously using EventMachine since it takes a couple of seconds.
      EM.defer do
        Pony.mail(:from => "Deep Blue Parts <#{CheesyCommon::Config.gmail_user}>", :to => to,
                  :subject => subject, :body => body, :via => :smtp,
                  :via_options => { :address => "smtp.gmail.com", :port => "587",
                                    :enable_starttls_auto => true,
                                    :user_name => CheesyCommon::Config.gmail_user.split("@").first,
                                    :password => CheesyCommon::Config.gmail_password,
                                    :authentication => :plain, :domain => "localhost.localdomain" })
      end
    end

    get "/" do
      redirect "/projects"
    end

    get "/login" do
      redirect "/logout" if @user
      @redirect = params[:redirect] || "/"

      if CheesyCommon::Config.enable_wordpress_auth
        member = CheesyCommon::Auth.get_user(request)
        if member.nil?
          redirect "#{CheesyCommon::Config.members_url}?site=parts&path=#{request.path}"
        else
          user = User[:wordpress_user_id => member.id]
          unless user
            user = User.create(:wordpress_user_id => member.id, :first_name => member.name[1],
                               :last_name => member.name[0], :permission => "editor", :enabled => 1,
                               :email => member.email, :password => "", :salt => "")
          end
          session[:user_id] = user.id
          redirect @redirect
        end
      end

      if params[:failed] == "1"
        @alert = "Invalid e-mail address or password."
      elsif params[:disabled] == "1"
        @alert = "Your account is currently disabled."
      end
      erb :login
    end

    post "/login" do
      user = User.authenticate(params[:email], params[:password])
      redirect "/login?failed=1" if user.nil?
      redirect "/login?disabled=1" if user.enabled == 0
      session[:user_id] = user.id
      redirect params[:redirect]
    end

    get "/logout" do
      session[:user_id] = nil
      if CheesyCommon::Config.enable_wordpress_auth
        redirect "#{CheesyCommon::Config.members_url}/logout"
      else
        redirect "/login"
      end
    end
    get "/uploads/*" do
          path = params[:splat].first
          type = 'application/pdf'
          type = 'application/octet-stream' unless path.end_with? ".pdf"
          send_file "./uploads/#{path}", :path => path, :type => type
    end
    get "/new_project" do
      require_permission(@user.can_administer?)
      erb :new_project
    end

    get "/projects" do
      erb :projects
    end

    post "/projects" do
      require_permission(@user.can_administer?)

      # Check parameter existence and format.
      halt(400, "Missing project name.") if params[:name].nil?
      halt(400, "Missing part number prefix.") if params[:part_number_prefix].nil?
      halt(400, "Missing CAD platform.") if params[:cad_platform].nil?
      halt(400, "Invalid CAD platform.") unless Project::CAD_PLATFORM_MAP.include?(params[:cad_platform])

      project = Project.create(:name => params[:name], :part_number_prefix => params[:part_number_prefix], :hide_dashboards => 0, 
        :cad_platform => params[:cad_platform])

      redirect "/projects/#{project.id}"
    end

    before "/projects/:id*" do
      @project = Project[params[:id]]
      halt(400, "Invalid project.") if @project.nil?
    end
    before "/vendors/:id*" do
      @vendor = Vendor[params[:id]]
      halt(400, "Invalid Vendor.") if @vendor.nil?
    end

    get "/projects/:id" do
      if ["type", "name", "parent_part_id", "status"].include?(params[:sort])
        @part_sort = params[:sort].to_sym
      else
        @part_sort = :id
      end
      erb :project
    end

    get "/projects/:id/edit" do
      require_permission(@user.can_administer?)

      erb :project_edit
    end
    get "/vendors/:id/edit" do
      require_permission(@user.is_shoptech?)

      erb :vendor_edit
    end
    post "/vendors/:id/edit" do
      require_permission(@user.is_shoptech?)

      @vendor.name = params[:name] if params[:name]
      if params[:part_number_prefix]
        @vendor.part_number_prefix = params[:part_number_prefix]
      end

      if params[:avatar]
        file = params[:avatar][:tempfile]
        Dir.mkdir("./uploads/vendors/#{@vendor.id}") unless Dir.exist?("./uploads/vendors/#{@vendor.id}")
        File.delete("./uploads/vendors/#{@vendor.id}/avatar.png") if File.exist?("./uploads/vendors/#{@vendor.id}/avatar.png")
        File.open("./uploads/vendors/#{@vendor.id}/avatar.png", 'wb') do |f|
          f.write(file.read)
        end
      end


      @vendor.save
      redirect "/vendors/#{params[:id]}"
    end
    post "/projects/:id/edit" do
      require_permission(@user.can_administer?)

      @project.name = params[:name] if params[:name]
      if params[:part_number_prefix]
        @project.part_number_prefix = params[:part_number_prefix]
      end

      if params[:cad_platform]
        halt(400, "Invalid CAD platform.") unless Project::CAD_PLATFORM_MAP.include?(params[:cad_platform])
        @project.cad_platform = params[:cad_platform]
      end

      if params[:avatar]
        file = params[:avatar][:tempfile]
        Dir.mkdir("./uploads/projects/#{@project.id}") unless Dir.exist?("./uploads/projects/#{@project.id}")
        File.delete("./uploads/projects/#{@project.id}/avatar.png") if File.exist?("./uploads/projects/#{@project.id}/avatar.png")
        File.open("./uploads/projects/#{@project.id}/avatar.png", 'wb') do |f|
          f.write(file.read)
        end
      end


      @project.save
      redirect "/projects/#{params[:id]}"
    end

    get "/projects/:id/delete" do
      require_permission(@user.can_administer?)
      File.delete("./uploads/projects/#{@project.id}/avatar.png") if File.exist?("./uploads/projects/#{@project.id}/avatar.png")
      erb :project_delete
    end
    get "/vendors/:id/delete" do
      require_permission(@user.can_administer?)
      File.delete("./uploads/vendors/#{@vendor.id}/avatar.png") if File.exist?("./uploads/vendor/#{@vendor.id}/avatar.png")
      erb :vendor_delete
    end
    post "/vendors/:id/delete" do
      require_permission(@user.can_administer?)

      @vendor.delete
      redirect "/vendors"
    end
    post "/projects/:id/delete" do
      require_permission(@user.can_administer?)

      @project.delete
      redirect "/projects"
    end

    get "/projects/:id/dashboard" do
      erb :dashboard
    end
    get "/vendors/:id/new_part" do
      require_permission(@user.is_shoptech?)
      erb :new_vendor_part
    end
    get "/vendors/:id/parts" do
      erb :vendor_parts
    end
    get "/projects/:id/dashboard/parts" do
      if Part::STATUS_MAP.has_key?(params[:status]) || params[:status]=="drawing"
        @status = params[:status]
      end
      erb :dashboard_parts
    end

    get "/projects/:id/new_part" do
      require_permission(@user.can_edit?)

      @parent_part_id = params[:parent_part_id]
      @type = params[:type] || "part"
      if @type == "cots"
        @vendor = Vendor[1]
        # halt(400, @vendor)
        halt(400, "Invalid Vendor.") if @vendor.nil?
      end
      halt(400, "Invalid part type.") unless Part::PART_TYPES.include?(@type)
      erb :new_part
    end

    get "/dashboards" do
      erb :dashboards
    end
    post "/vendor_parts" do
      require_permission(@user.is_shoptech?)

      # Check parameter existence and format.
      halt(400, "Missing vendor ID.") if params[:vendor_id].nil? || params[:vendor_id] !~ /^\d+$/
      halt(400, "Missing part name.") if params[:name].nil? || params[:name].empty?
      halt(400, "Missing part number.") if params[:part_number].nil?
	  halt(400, "Missing unit cost.") if params[:unit_cost].nil? || params[:unit_cost] !~ /^\d+\.*\d*$/
      halt(400, "Missing qty_per_unit.") if params[:qty_per_unit].nil? || params[:qty_per_unit] !~ /^\d+$/
      halt(400, "Missing part link.") if params[:link].nil? || params[:link].empty?


      vendor = Vendor[params[:vendor_id].to_i]
      halt(400, "Invalid vendor.") if vendor.nil?


      part = VendorPart.new(:name => params[:name].gsub("\"", "&quot;"), :link=> params[:link].gsub("\"", "&quot;"), :vendor_id => params[:vendor_id], :unit_cost => params[:unit_cost], :qty_per_unit => params[:qty_per_unit], :part_number => params[:part_number] )
      part.save
      redirect "/vendor_parts/#{part.id}"
    end
    get "/vendor_parts/:id" do
      @part = VendorPart[params[:id]]
      halt(400, "Invalid Vendor part.") if @part.nil?
      if ["name", "vendor_id", "link"].include?(params[:sort])
        @part_sort = params[:sort].to_sym
      else
        @part_sort = :id
      end
      erb :vendor_part
    end
    post "/parts" do
      require_permission(@user.can_edit?)

      # Check parameter existence and format.
      halt(400, "Missing project ID.") if params[:project_id].nil? || params[:project_id] !~ /^\d+$/
      halt(400, "Missing part type.") if params[:type].nil?
      halt(400, "Invalid part type.") unless Part::PART_TYPES.include?(params[:type])
      halt(400, "Missing part name.") if params[:name].nil? || params[:name].empty?
      if params[:parent_part_id] && params[:parent_part_id] !~ /^\d+$/
        halt(400, "Invalid parent part ID.")
      end

      project = Project[params[:project_id].to_i]
      halt(400, "Invalid project.") if project.nil?

      parent_part = nil
      if params[:parent_part_id]
        parent_part = Part[:id => params[:parent_part_id].to_i, :project_id => project.id,
                           :type => "assembly"]
        halt(400, "Invalid parent part.") if parent_part.nil?
      end

      part = Part.generate_number_and_create(project, params[:type], parent_part)
      part.name = params[:name].gsub("\"", "&quot;")
      if params[:type] == "cots"
        part.part_number = VendorPart[params[:part_id]].part_number
        part.vendor_id = params[:vendor_id]
        part.vendor_part_id = params[:part_id]
        part.quantity = params[:quantity]
        part.status = "ordered"
        part.drawing_created = 1
      else
        part.status = "designing"
        part.drawing_created = 0
        part.quantity = ""

      end
      part.rev = ""
      part.mfg_method = "Manual/Hand tools"
      part.finish = "None"
      part.rev_history = ""
      part.priority = 1
      part.trello_link = ""
      part.save
      redirect "/parts/#{part.id}"
    end

    get "/parts/:id" do
      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      if ["type", "name", "parent_part_id", "status"].include?(params[:sort])
        @part_sort = params[:sort].to_sym
      else
        @part_sort = :id
      end
      erb :part
    end

    get "/parts/:id/edit" do
      require_permission(@user.is_shoptech?)

      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      @referrer = request.referrer
      erb :part_edit
    end

    post "/parts/:id/edit" do
      require_permission(@user.is_shoptech?)

      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      halt(400, "Missing part name.") if @part.type!="cots" && params[:name] && params[:name].empty?

      if params[:status]
        halt(400, "Invalid status.") unless Part::STATUS_MAP.include?(params[:status])
        @part.status = params[:status]
      end

      if @user.can_edit?
        @part.name = params[:name].gsub("\"", "&quot;") if params[:name]
        @part.quantity = params[:quantity] if params[:quantity]

        if params[:documentation]
          file = params[:documentation][:tempfile]
          # Create directories if they do not exist already
          Dir.mkdir("./uploads/#{@part.full_part_number}") unless Dir.exist?("./uploads/#{@part.full_part_number}")
          Dir.mkdir("./uploads/#{@part.full_part_number}/docs") unless Dir.exist?("./uploads/#{@part.full_part_number}/docs")
          File.delete("./uploads/#{@part.full_part_number}/docs/#{@part.full_part_number}.pdf") if File.exist?("./uploads/#{@part.full_part_number}/docs/#{@part.full_part_number}.pdf")
          File.open("./uploads/#{@part.full_part_number}/docs/#{@part.full_part_number}.pdf", 'wb') do |f|
            f.write(file.read)
          end
        end

        if params[:drawing]
          file = params[:drawing][:tempfile]
          # Create directories if they do not exist already
          Dir.mkdir("./uploads/#{@part.full_part_number}") unless Dir.exist?("./uploads/#{@part.full_part_number}")
          Dir.mkdir("./uploads/#{@part.full_part_number}/drawing") unless Dir.exist?("./uploads/#{@part.full_part_number}/drawing")
          # File.delete("./uploads/#{@part.full_part_number}/drawing/#{@part.full_part_number+"_"+@part.increment_revision(@part.rev)}.pdf") if File.exist?("./uploads/#{@part.full_part_number}/drawing/#{@part.full_part_number+"_"+@part.increment_revision(@part.rev)}.pdf")
          File.open("./uploads/#{@part.full_part_number}/drawing/#{@part.full_part_number+"_"+@part.increment_revision(@part.rev_history.split(",").last)}.pdf", 'wb') do |f|
            f.write(file.read)
          end
          @part.rev = @part.increment_revision(@part.rev_history.split(",").last)
          if @part.rev == "A"
            @part.rev_history << @part.rev
          else
            @part.rev_history << ",#{@part.rev}"
          end
          @part.drawing_created = 1
        end

        if params[:drawing_link]
          @part.drawing_link = params[:drawing_link].strip
          @part.drawing_created = 1
        end

        if params[:toolpath]
          file = params[:toolpath][:tempfile]
          # Create directories if they do not exist already
          Dir.mkdir("./uploads/#{@part.full_part_number}") unless Dir.exist?("./uploads/#{@part.full_part_number}")
          Dir.mkdir("./uploads/#{@part.full_part_number}/toolpath") unless Dir.exist?("./uploads/#{@part.full_part_number}/toolpath")
          File.delete("./uploads/#{@part.full_part_number}/toolpath/#{@part.full_part_number}.dxf") if File.exist?("./uploads/#{@part.full_part_number}/toolpath/#{@part.full_part_number}.dxf")
          File.open("./uploads/#{@part.full_part_number}/toolpath/#{@part.full_part_number}.dxf", 'wb') do |f|
              f.write(file.read)
          end
        end

        if params[:mfg_method]
          halt(400, "Invalid manufacturing method.") unless Part::MFG_MAP.include?(params[:mfg_method])
          @part.mfg_method = params[:mfg_method]
        end
        if params[:finish]
          halt(400, "Invalid finish type.") unless Part::FINISH_MAP.include?(params[:finish])
          @part.finish = params[:finish]
        end
        @part.rev = params[:rev] if (params[:rev] && !params[:drawing])
      end
      if @user.is_shoptech?
        @part.quantity = params[:quantity] if params[:quantity]
        @part.notes = params[:notes] if params[:notes]
        @part.priority = params[:priority] if params[:priority]
      end
      @part.modified!(:rev_history)
      @part.modified!(:rev)
      @part.save_changes
      redirect params[:referrer] || "/parts/#{params[:id]}"
    end
    get "/vendor_parts/:id/edit" do
      require_permission(@user.is_shoptech?)

      @part = VendorPart[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      @referrer = request.referrer
      erb :vendor_part_edit
    end

    post "/vendor_parts/:id/edit" do
      require_permission(@user.is_shoptech?)

      @part = VendorPart[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      halt(400, "Missing part name.") if params[:name] && params[:name].empty?
      @part.qty_per_unit = params[:qty_per_unit] if params[:qty_per_unit]
      @part.unit_cost = params[:unit_cost] if params[:unit_cost]
      @part.name = params[:name] if params[:name]
      @part.part_number = params[:part_number] if params[:part_number]
      @part.link = params[:link] if params[:link]

      @part.save_changes
      redirect params[:referrer] || "/vendor_parts/#{params[:id]}"
    end
    get "/parts/:id/release" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      @referrer = request.referrer
      erb :part_release
    end

    post "/parts/:id/release" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      project_id = @part.project_id
      halt(400, "Invalid part.") if @part.nil?

      # Drawing Release Trigger
      if (@part.quantity == "")
        halt(400, "No quantity set.")
      elseif (@part.drawing_created == 0)
        halt(400, "No drawing uploaded")
      else
	if CheesyCommon::Config.slack_enabled
		$slack_bot.chat_postMessage(channel: 'parts-notifications',
					    as_user: true,
					    attachments: [
							   {
							     "fallback": "New part ready for manufacture.",
							     "color": "#36a64f",
							     "pretext": "New part ready for manufacture!",
							     "title": "#{@part.full_part_number} (#{@part.name})",
							     "title_link": "#{CheesyCommon::Config.base_address}/parts/#{@part.id}",
							     "fields": [
									  {
									    "title": "Parent assembly",
									    "value": "#{@part.parent_part.full_part_number} (#{@part.parent_part.name})",
									    "short": false
									  },
									  {
									    "title": "Quantity",
									    "value": "#{@part.quantity}",
									    "short": true
									  },
									  {
									    "title": "Revision",
									    "value": "#{@part.rev}",
									    "short": true
									  }
										    ],
							     "footer": "Deep Blue Parts",
							     "footer_icon": "http://carlmontrobotics.org/images/ico/TabIcon.png",
							     "ts": "#{Time.now.to_i}"
							   }
							 ]) unless @part.status == "ready"
	end
        # Post to Trello and save link
        if (@part.trello_link == "") and CheesyCommon::Config.trello_enabled
          EM.defer do
            trello_bot = Trello::Member.find("partsbot")
            fab = trello_bot.boards[0]
            list = fab.lists.first # MAKE SURE THE BOARD HAS A LIST

            @part.quantity.to_i.times do |serial|
              card = Trello::Card.create(name: "Fabricate #{@part.full_part_number}-#{serial+1} (#{@part.name})",
                                         desc: "Parts DB link: #{CheesyCommon::Config.base_address}/parts/#{@part.id}",
                                         list_id: list.id)
              @part.trello_link << (card.url + ",")
              checklist = Trello::Checklist.create(name: "Fabrication Checklist",
                                                   board_id: fab.id,
                                                   card_id: card.id)
              checklist_items = ["Verify that the current revision letter matches the drawing",
                               "Read the dimension drawing, bring any issues to DESIGN",
                               "Update parts DB status to Manufacturing in Progress",
                               "Identify tools/resources needed for fabrication of part",
                               "Ensure proper usage and safety procedures are known and followed",
                               "Ensure that work is done over a whiteboard or plywood",
                               "Check layout",
                               "Verify layout with student lead or mentor",
                               "Fabricate part",
                               "Inspect part, note any dimensions which are out of tolerance",
                               "Bring part to QA for inspection and sign-off",
                               "Serialize the part using an engraver (or pen, if specified)",
                               "Clean the part and prepare it for finishing, if specified",
                               "Bag and file the part in the appropriate place",
                               "File the completed drawing (and traveler, if used) in the appropriate binder",
                               "Update trello, parts database, and your task lead"]
              checklist_items.each do |entry|
                checklist.add_item(entry)
              end
              @part.save_changes
            end
          end
        end
      end
      @part.status = "ready"
      @part.save_changes
      redirect "/parts/#{@part.id}"
    end

    get "/parts/:id/delete" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      @referrer = request.referrer
      erb :part_delete
    end

    post "/vendor_parts/:id/delete" do
      require_permission(@user.is_shoptech?)

      @part = VendorPart[params[:id]]
      vendor_id = @part.vendor_id
      halt(400, "Invalid part.") if @part.nil?
      @part.delete
      params[:referrer] = nil if params[:referrer] =~ /\/vendor_parts\/#{params[:id]}$/
      redirect params[:referrer] || "/vendors/#{vendor_id}"
    end
    get "/vendor_parts/:id/delete" do
      require_permission(@user.is_shoptech?)

      @part = VendorPart[params[:id]]
      halt(400, "Invalid part.") if @part.nil?
      @referrer = request.referrer
      erb :vendor_part_delete
    end

    post "/parts/:id/delete" do
      require_permission(@user.can_edit?)

      @part = Part[params[:id]]
      project_id = @part.project_id
      halt(400, "Invalid part.") if @part.nil?
      halt(400, "Can't delete assembly with existing children.") unless @part.child_parts.empty?
      FileUtils.rm_rf("./uploads/#{@part.full_part_number}")
      @part.delete
      params[:referrer] = nil if params[:referrer] =~ /\/parts\/#{params[:id]}$/
      redirect params[:referrer] || "/projects/#{project_id}"
    end

    get "/new_user" do
      require_permission(@user.can_administer?)
      @admin_new_user = true
      erb :new_user
    end

    get "/users" do
      require_permission(@user.can_administer?)
      erb :users
    end

    post "/users" do
      require_permission(@user.can_administer?)

      halt(400, "Missing email.") if params[:email].nil? || params[:email].empty?
      halt(400, "Invalid email.") unless params[:email] =~ /^\S+@\S+\.\S+$/
      halt(400, "User #{params[:email]} already exists.") if User[:email => params[:email]]
      halt(400, "Missing first name.") if params[:first_name].nil? || params[:first_name].empty?
      halt(400, "Missing last name.") if params[:last_name].nil? || params[:last_name].empty?
      halt(400, "Missing password.") if params[:password].nil? || params[:password].empty?
      halt(400, "Missing permission.") if params[:permission].nil? || params[:permission].empty?
      halt(400, "Invalid permission.") unless User::PERMISSION_MAP.include?(params[:permission])
      user = User.new(:email => params[:email], :first_name => params[:first_name],
                      :last_name => params[:last_name], :permission => params[:permission],
                      :theme => "classic", :enabled => (params[:enabled] == "on") ? 1 : 0)
      user.set_password(params[:password])
      user.save
      redirect "/users"
    end

    get "/users/:id/edit" do
      require_permission(@user.can_administer?)

      @user_edit = User[params[:id]]
      halt(400, "Invalid user.") if @user_edit.nil?
      erb :user_edit
    end

    post "/users/:id/edit" do
      require_permission(@user.can_administer?)

      @user_edit = User[params[:id]]
      halt(400, "Invalid user.") if @user_edit.nil?
      @user_edit.email = params[:email] if params[:email]
      @user_edit.first_name = params[:first_name] if params[:first_name]
      @user_edit.last_name = params[:last_name] if params[:last_name]
      @user_edit.set_password(params[:password]) if params[:password] && !params[:password].empty?
      @user_edit.permission = params[:permission] if params[:permission]
      @user_edit.theme = params[:theme] if params[:theme]
      old_enabled = @user_edit.enabled
      @user_edit.enabled = (params[:enabled] == "on") ? 1 : 0
      if @user_edit.enabled == 1 && old_enabled == 0
        email_body = <<-EOS.dedent
          Hello #{@user_edit.first_name},

          Your account on Deep Blue Parts has been approved.
          You can log into the system at #{CheesyCommon::Config.base_address}.

          Cheers,

          Your Friendly Neighborhood Deep Blue Parts Bot
        EOS
        send_email(@user_edit.email, "Account approved", email_body)
      end
      @user_edit.save
      redirect "/users"
    end
    get "/user/preferences" do
      erb :user_prefs
    end

    post "/user/preferences" do
      halt(400, "Invalid user.") if @user.nil?
      @user.email = params[:email] if params[:email]
      @user.first_name = params[:first_name] if params[:first_name]
      @user.last_name = params[:last_name] if params[:last_name]
      @user.set_password(params[:password]) if params[:password] && !params[:password].empty?
      @user.theme = params[:theme] if params[:theme]
      @user.save
      redirect "/user/preferences"
    end

    get "/users/:id/delete" do
      require_permission(@user.can_administer?)

      @user_delete = User[params[:id]]
      halt(400, "Invalid user.") if @user_delete.nil?
      erb :user_delete
    end

    post "/users/:id/delete" do
      require_permission(@user.can_administer?)

      @user_delete = User[params[:id]]
      halt(400, "Invalid user.") if @user_delete.nil?
      @user_delete.delete
      redirect "/users"
    end
    get "/vendors" do
      require_permission(@user.is_shoptech?)
      erb :vendors
    end
    before "/vendors/:id*" do
      @vendor = Vendor[params[:id]]
      halt(400, "Invalid project.") if @vendor.nil?
    end

    get "/vendors/:id" do
      if ["type", "name", "parent_part_id", "status"].include?(params[:sort])
        @part_sort = params[:sort].to_sym
      else
        @part_sort = :id
      end
      erb :vendor
    end
    get "/new_vendor" do
      require_permission(@user.is_shoptech?)
      erb :new_vendor
    end
    post "/vendors" do
      require_permission(@user.is_shoptech?)

      # Check parameter existence and format.
      halt(400, "Missing vendor name.") if params[:name].nil?
      halt(400, "Missing part number prefix.") if params[:part_number_prefix].nil?

      vendor = Vendor.create(:name => params[:name], :part_number_prefix => params[:part_number_prefix])

      redirect "/vendors/#{vendor.id}"
    end
    get "/register" do
      @admin_new_user = false
      erb :new_user
    end

    post "/register" do
      halt(400, "Missing email.") if params[:email].nil? || params[:email].empty?
      halt(400, "Invalid email.") unless params[:email] =~ /^\S+@\S+\.\S+$/
      halt(400, "User #{params[:email]} already exists.") if User[:email => params[:email]]
      halt(400, "Missing first name.") if params[:first_name].nil? || params[:first_name].empty?
      halt(400, "Missing last name.") if params[:last_name].nil? || params[:last_name].empty?
      halt(400, "Missing password.") if params[:password].nil? || params[:password].empty?
      user = User.new(:email => params[:email], :first_name => params[:first_name],
                      :last_name => params[:last_name], :permission => "readonly",
                      :enabled => 0, :theme => "")
      user.set_password(params[:password])
      user.save
      email_body = <<-EOS.dedent
        Hello,

        This is a notification that #{user.first_name} #{user.last_name} has created an account on Deep Blue
        Parts and it is disabled pending approval.
        Please visit the user control panel at #{CheesyCommon::Config.base_address}

        Cheers,

        Deep Blue Parts Server
      EOS
      send_email(CheesyCommon::Config.gmail_user, "Approval needed for #{user.email}", email_body)
      erb :register_confirmation
    end

    get "/orders" do
      erb :orders_project_list
    end

    get "/projects/:id/orders/open" do
      @no_vendor_order_items = OrderItem.where(:order_id => nil, :project_id => params[:id])
      @vendor_orders = Order.filter(:status => "open").where(:project_id => params[:id]).
          order(:vendor_name, :ordered_at)
      @show_new_item_form = params[:new_item] == "true"
      erb :open_orders
    end

    get "/projects/:id/orders/ordered" do
      @vendor_orders = Order.filter(:status => "ordered").where(:project_id => params[:id]).
          order(:vendor_name, :ordered_at)
      erb :completed_orders
    end

    get "/projects/:id/orders/complete" do
      @vendor_orders = Order.filter(:status => "received").where(:project_id => params[:id]).
          order(:vendor_name, :ordered_at)
      erb :completed_orders
    end

    get "/projects/:id/orders/all" do
      @vendor_orders = Order.where(:project_id => params[:id]).order(:vendor_name, :ordered_at)
      if params[:filter]
        key, value = params[:filter].split(":")
        @vendor_orders = @vendor_orders.filter(key.to_sym => value)
      end
      erb :completed_orders
    end

    get "/projects/:id/orders/stats" do
      @orders = Order.filter(:status => "open").invert.where(:project_id => params[:id]).all
      @orders_by_vendor = @orders.inject({}) do |map, order|
        map[order.vendor_name] ||= []
        map[order.vendor_name] << order
        map
      end

      @orders_by_purchaser = @orders.inject({}) do |map, order|
        map[order.paid_for_by] ||= {}
        map[order.paid_for_by][:reimbursed] ||= 0
        map[order.paid_for_by][:outstanding] ||= 0
        if order.reimbursed == 1
          map[order.paid_for_by][:reimbursed] += order.total_cost
        else
          map[order.paid_for_by][:outstanding] += order.total_cost
        end
        map
      end

      erb :order_stats
    end

    post "/projects/:id/order_items" do
      require_permission(@user.can_edit?)

      # Match vendor to an existing open order or create it if there isn't one.
      if params[:vendor].nil? || params[:vendor].empty?
        order_id = nil
      else
        order = Order.where(:project_id => @project.id, :vendor_name => params[:vendor],
                            :status => "open").first
        if order.nil?
          order = Order.create(:project => @project, :vendor_name => params[:vendor], :status => "open", :reimbursed => 0)
        end
        order_id = order.id
      end

      OrderItem.create(:project => @project, :order_id => order_id, :quantity => params[:quantity].to_i,
                       :part_number => params[:part_number], :description => params[:description],
                       :unit_cost => params[:unit_cost].to_f, :notes => params[:notes])
      redirect "/projects/#{@project.id}/orders/open"
    end

    get "/projects/:project_id/order_items/:id/editable" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:id]]
      halt(400, "Invalid order item.") if @item.nil?
      erb :edit_order_item
    end

    post "/projects/:project_id/order_items/edit" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:order_item_id]]
      halt(400, "Invalid order item.") if @item.nil?

      # Handle a vendor change.
      order_id = @item.order.id rescue nil
      old_vendor = @item.order.vendor_name rescue ""
      new_vendor = params[:vendor]
      unless old_vendor == new_vendor
        order = Order.where(:project_id => @project.id, :vendor_name => params[:vendor],
                            :status => "open").first
        if order.nil?
          order = Order.create(:project => @project, :vendor_name => params[:vendor], :status => "open")
        end
        order_id = order.id
      end

      @item.update(:order_id => order_id, :quantity => params[:quantity].to_i,
                   :part_number => params[:part_number], :description => params[:description],
                   :unit_cost => params[:unit_cost].gsub(/\$/, "").to_f, :notes => params[:notes])
      redirect params[:referrer]
    end

    get "/projects/:project_id/order_items/:id/delete" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:id]]
      halt(400, "Invalid order item.") if @item.nil?
      @referrer = request.referrer
      erb :order_item_delete
    end

    post "/projects/:project_id/order_items/:id/delete" do
      require_permission(@user.can_edit?)

      @item = OrderItem[params[:id]]
      halt(400, "Invalid order item.") if @item.nil?
      @item.delete
      redirect params[:referrer]
    end

    get "/projects/:id/orders/:order_id" do
      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?
      erb :order
    end

    post "/projects/:id/orders/:order_id/edit" do
      require_permission(@user.can_edit?)

      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?
      @order.update(:status => params[:status], :ordered_at => params[:ordered_at],
                    :paid_for_by => params[:paid_for_by], :tax_cost => params[:tax_cost].gsub(/\$/, ""),
                    :shipping_cost => params[:shipping_cost].gsub(/\$/, ""), :notes => params[:notes],
                    :reimbursed => params[:reimbursed] ? 1 : 0)
      redirect "/projects/#{@project.id}/orders/#{@order.id}"
    end

    get "/projects/:id/orders/:order_id/delete" do
      require_permission(@user.can_edit?)

      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?
      halt(400, "Can't delete a non-empty order.") unless @order.order_items.empty?
      erb :order_delete
    end

    post "/projects/:id/orders/:order_id/delete" do
      require_permission(@user.can_edit?)

      @order = Order[params[:order_id]]
      halt(400, "Invalid order.") if @order.nil?
      halt(400, "Can't delete a non-empty order.") unless @order.order_items.empty?
      @order.delete
      redirect "/orders"
    end
  end
end
