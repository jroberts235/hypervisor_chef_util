# This script queries the Chef server for nodes in the role[hypervisor] 
# using the Chef API and a valid user name and .pem file.
# It gathers information on any nodes, and displays stats
# on the hypervisor itself and all guests of that hypervisor.
#
# There is a Gemfile. Use bundler to install all dependencies.
#
# NOTE: This script requires that the KVM plugin be installed into 
# Ohai on each hypervisor. Chef only gets updated stats after a 
# successful chef-client run.
#
# https://github.com/albertsj1/ohai-plugins/blob/master/kvm_extensions.rb

#! env ruby
require 'chef' 
require 'chef/rest' 
require 'chef/search/query' 
require 'chef/node' 
require 'json'
require 'mixlib/cli'

class Options
    include Mixlib::CLI


    option :chef_username,
        :short => "-u USERNAME",
        :long => "--name USERNAME",
        :description => "User to use when talking with the Chef API",
        :required => true


    option :pem_file,
        :short => "-p PEMFILE",
        :long => "--pem PEMFILE",
        :description => "Pem file to use when talking with the Chef API",
        :required => false


    option :chef_server_hostname,
        :short => "-H HOSTNAME",
        :long => "--host HOSTNAME",
        :description => "The hostname of the chef server",
        :default => "chefserver.ops.nastygal.com",
        :required => false


    option :chef_server_port,
        :short => "-p PORT",
        :long => "--port PORT",
        :description => "The port the chef server is listening on",
        :default => "4000",
        :required => false


    option :hypervisor,
        :short => "-h CHEFNODENAME",
        :long => "--hypervisor CHEFNODENAME",
        :description => "Get stats on a single hypervisor using the Chef node name",
        :required => false


    option :help,
        :long => "--help",
        :short => "-h",
        :description => "Show this message",
        :on => :tail,
        :show_options => true,
        :boolean => true,
        :exit => 0
end

class ChefClient
    attr_accessor :name, :key, :url
    def initialize(name, key, url)
        @name = name 
        @key  = key
        @url  = url
  
        Chef::Config[:node_name]=name
        Chef::Config[:client_key]=key
        Chef::Config[:chef_server_url]=url
    end
end 


class NodeAttrs
    attr_accessor :results
    def initialize(node)
        var = Chef::Node.load(node)
        @results = var.display_hash
    end
end


class NodeQuery
    def initialize(url)
        @var = Chef::Search::Query.new(url)
    end

    def search(query)
        nodes = []
        results = @var.search('node', query)
        justNodes = results[0..(results.count - 3)] # drop the last 2 indexes
        justNodes[0].each do |host|
            nodes << host.to_s[/\[(.*?)\]/].tr('[]', '')  # take the name leave the canoli
        end
        return nodes
    end
end


class Stats
    attr_accessor(:core_total, :mem_total_in_KiB)
    def initialize
        @core_total = 0
        @mem_total_in_KiB = 0
    end

    def add_to_core_count(cores)
        @core_total += cores 
    end

    def add_to_mem_total(memory_in_KiB)
        @mem_total_in_KiB += memory_in_KiB
    end
end


begin
    # Pull in the options
    options = Options.new
    options.parse_options


    # Required variables
    username    = options.config[:chef_username]
    chefurl     = "http://#{options.config[:chef_server_hostname]}:#{options.config[:chef_server_port]}"

    if options.config[:pem_file] == nil # the pem file may just be the username.pem
        pemfile = "#{options.config[:chef_username]}.pem"
    else
        pemfile = options.config[:pem_file]
    end
    

    # AUTH - connect to ChefServer with valid user and pemfile
    credentials = ChefClient.new(username, pemfile, chefurl)


    # SEARCH - get array of nodes based on search
    q = NodeQuery.new(credentials.url)

    if options.config[:hypervisor] == nil
        nodes = q.search('role:hypervisor')
    else
        nodes = []
        nodes << options.config[:hypervisor]
    end

    hypervisors = {}
    guests = {}


    nodes.each do |node| # Get per node attrs and create a hash key for each node
        a = NodeAttrs.new(node)
        stats = Stats.new


        hypervisor_name         = node
        time_of_last_chef_run   = Time.at(a.results['automatic']['ohai_time'])


        # Take the attrs generated by the KVM:Ohai plugin and assign them to the key "attrs"
        hypervisors[node]       = { 'attrs' => a.results['automatic']['virtualization']['kvm'] }


        # Get specific stats from node
        hypervisor_memory       = hypervisors[node]['attrs']['hardware']['Memory size']
        hypervisor_memory_float = (hypervisor_memory.split(" ", 2))[0].to_f
        hypervisor_cores        = (hypervisors[node]['attrs']['hardware']['CPU(s)']).to_i
        guest_cpu_total         = hypervisors[node]['attrs']['guest_cpu_total']
        guest_maxmemory_total   = hypervisors[node]['attrs']['guest_maxmemory_total']
        guest_used_memory_total = hypervisors[node]['attrs']['guest_usedmemory_total']
        guests                  = hypervisors[node]['attrs']['guests']


        # Hypervisor stats
        puts # blank line
        printf "%-41s %-30s\n", "Host: #{hypervisor_name}", "Chef Run: #{time_of_last_chef_run}"
        puts "Host Mem: #{hypervisor_memory}"
        puts "Host Cores: #{hypervisor_cores}"
        puts "Guest CPU Total: #{guest_cpu_total}" 
        puts "Guest Max Mem Total: #{guest_maxmemory_total}"
        puts "Guest Used Mem Total: #{guest_used_memory_total}"
        puts # blank line
        printf "%-10s %-17s %-9s %-15s %-14s %-20s\n", "Guests:", "Host", "Cores", "Max Memory", "Used Memory", "State"


        guests.keys.each do |guest| # Get specific stats for each guest on the node
            name           = guest
            state          = hypervisors[node]['attrs']['guests'][guest]['state']
            cores          = (hypervisors[node]['attrs']['guests'][guest]['CPU(s)']).to_i
            used_mem       = hypervisors[node]['attrs']['guests'][guest]['Used memory']
            max_mem_in_KiB = hypervisors[node]['attrs']['guests'][guest]['Max memory']
            mem_float      = (max_mem_in_KiB.split(" ", 2))[0].to_f 


            if state == "running" # only count resources from running guests
                stats.add_to_core_count(cores)
                stats.add_to_mem_total(mem_float)
            end


            # Guests Stats
            printf "%-10s %-20s %-2s %15s %15s %10s\n", "", guest, cores, max_mem_in_KiB, used_mem, state

        end # guest.keys.each


        # Calculate total core and memory usage 
        cores = stats.core_total.to_f / hypervisor_cores.to_f
        mem = stats.mem_total_in_KiB / hypervisor_memory_float


        puts # blank line
        puts "Resource Statistics - Cores: #{(cores * 100).to_i}%  Memory: #{(mem * 100).to_i}%"
        60.times { print "-" }
        puts # blank line

    end # nodes.each

rescue => e
    puts e.message

end # end of begin
