test_name "Revert VMs"

  # NOTE: this code is shamelessly stolen from facter's 'domain' fact, but
  # we don't have access to facter at this point in the run.  Also, this
  # utility method should perhaps be moved to a more central location in the
  # framework.
  def get_domain_name(host)
    domain = nil
    search = nil
    on host, "cat /etc/resolv.conf"
    resolv_conf = stdout
    resolv_conf.each_line { |line|
      if line =~ /^\s*domain\s+(\S+)/
        domain = $1
      elsif line =~ /^\s*search\s+(\S+)/
        search = $1
      end
    }
    return domain if domain
    return search if search
  end

  def amiports(host)
    roles = host['roles']
    ports = [22]

    if roles.include? 'database'
      ports << 8080
      ports << 8081
    end

    if roles.include? 'master'
      ports << 8140
    end

    if roles.include? 'dashboard'
      ports << 443
    end

    ports
  end

  snap = options[:snapshot] || options[:type]
  snap = 'git' if snap == 'gem'  # Sweet, sweet consistency
  snap = 'git' if snap == 'manual'  # Sweet, sweet consistency
  fail_test "You must specifiy a snapshot when using pe_noop" if snap == 'pe_noop'

  if options[:vmrun] == 'solaris'
    fog_file = nil
    if File.exists?( File.join(ENV['HOME'], '.fog') )
      fog_file = YAML.load_file( File.join(ENV['HOME'], '.fog') )
    end
    fail_test "Cant load ~/.fog config" unless fog_file

    hypername = fog_file[:default][:solaris_hypervisor_server]
    vmpath    = fog_file[:default][:solaris_hypervisor_vmpath]
    snappaths = fog_file[:default][:solaris_hypervisor_snappaths]

    hyperconf = {
      'HOSTS'  => {
        hypername => { 'platform' => 'solaris-11-sparc' }
      },
      'CONFIG' => {
        'user' => fog_file[:default][:solaris_hypervisor_username] || ENV['USER'],
        'ssh'  => {
          :keys => fog_file[:default][:solaris_hypervisor_keyfile] || "#{ENV['HOME']}/.ssh/id_rsa"
        }
      }
    }

    hyperconfig = PuppetAcceptance::TestConfig.new( hyperconf, options )

    logger.notify "Connecting to hypervisor at #{hypername}"
    hypervisor = PuppetAcceptance::Host.create( hypername, options, hyperconfig )

    # This is a hack; we want to pull from the 'foss' snapshot
    snap = 'foss' if snap == 'git'

    hosts.each do |host|
      vm_name = host['vmname'] || host.name

      logger.notify "Reverting #{vm_name} to snapshot #{snap}"
      start = Time.now
      on hypervisor, "sudo /sbin/zfs rollback -Rf #{vmpath}/#{vm_name}@#{snap}"
      snappaths.each do |spath|
        logger.notify "Reverting #{vm_name}/#{spath} to snapshot #{snap}"
        on hypervisor, "sudo /sbin/zfs rollback -Rf #{vmpath}/#{vm_name}/#{spath}@#{snap}"
      end
      time = Time.now - start
      logger.notify "Spent %.2f seconds reverting" % time

      logger.notify "Booting #{vm_name}"
      start = Time.now
      on hypervisor, "sudo /sbin/zoneadm -z #{vm_name} boot"
      logger.notify "Spent %.2f seconds booting #{vm_name}" % (Time.now - start)
    end
    hypervisor.close

  elsif options[:vmrun] == 'vsphere'
    require 'yaml' unless defined?(YAML)
    require File.expand_path(File.join(File.dirname(__FILE__),
                                       '..', '..','lib', 'puppet_acceptance',
                                       'utils', 'vsphere_helper'))

    # support Fog/Cloud Provisioner layout
    # (ie, someplace besides my made up conf)
    vInfo = nil
    if File.exists?( File.join(ENV['HOME'], '.fog') )
      vInfo = YAML.load_file( File.join(ENV['HOME'], '.fog') )
    elsif File.exists? '/etc/plharness/vsphere'
      vInfo = YAML.load_file '/etc/plharness/vsphere'
      logger.notify(
        "Use of /etc/plharness/vsphere as a config file is deprecated.\n" +
        "Please use ~/.fog instead\n" +
        "See http://docs.puppetlabs.com/pe/2.0/cloudprovisioner_configuring.html for format"
      )
    end
    fail_test "Cant load vSphere config" unless vInfo

    vsphere_credentials = {}
    if vInfo['location'] && vInfo['user'] && vInfo['pass']
      vsphere_credentials[:server] = vInfo['location']
      vsphere_credentials[:user]   = vInfo['user']
      vsphere_credentials[:pass]   = vInfo['pass']

    elsif vInfo[:default][:vsphere_server] &&
          vInfo[:default][:vsphere_username] &&
          vInfo[:default][:vsphere_password]

      vsphere_credentials[:server] = vInfo[:default][:vsphere_server]
      vsphere_credentials[:user]   = vInfo[:default][:vsphere_username]
      vsphere_credentials[:pass]   = vInfo[:default][:vsphere_password]
    else
      fail_test "Invalid vSphere config"
    end

    # Do more than manage two different config files...
    logger.notify "Connecting to vsphere at #{vsphere_credentials[:server]}" +
      " with credentials for #{vsphere_credentials[:user]}"

    vsphere_helper = VsphereHelper.new vsphere_credentials

    vm_names = hosts.map {|h| h.name }
    vms = vsphere_helper.find_vms vm_names
    vm_names.each do |name|
      unless vm = vms[name]
        fail_test("Couldn't find VM #{name} in vSphere!")
      end

      snapshot = vsphere_helper.find_snapshot(vm, snap) or
        fail_test("Could not find snapshot #{snap} for vm #{vm.name}")

      logger.notify "Reverting #{vm.name} to snapshot #{snap}"
      start = Time.now
      # This will block for each snapshot...
      # The code to issue them all and then wait until they are all done sucks
      snapshot.RevertToSnapshot_Task.wait_for_completion

      time = Time.now - start
      logger.notify "Spent %.2f seconds reverting" % time

      unless vm.runtime.powerState == "poweredOn"
        logger.notify "Booting #{vm.name}"
        start = Time.now
        vm.PowerOnVM_Task.wait_for_completion
        logger.notify "Spent %.2f seconds booting #{vm.name}" % (Time.now - start)
      end
    end

  elsif options[:vmrun] == 'fusion'
    require 'rubygems' unless defined?(Gem)
    begin
      require 'fission'
    rescue LoadError
      fail_test "Unable to load fission, please ensure its installed"
    end

    available = Fission::VM.all.data.collect{|vm| vm.name}.sort.join(", ")
    logger.notify "Available VM names: #{available}"

    hosts.each do |host|
      fission_opts = host.defaults["fission"] || {}
      vm_name = host.defaults["vmname"] || host.name
      vm = Fission::VM.new vm_name
      fail_test("Could not find vm #{vm_name} for #{host}") unless vm.exists?

      available_snapshots = vm.snapshots.data.sort.join(", ")
      logger.notify "Available snapshots for #{host}: #{available_snapshots}"
      snap_name = fission_opts["snapshot"] || snap
      fail_test "No snapshot specified for #{host}" unless snap_name
      fail_test("Could not find snapshot #{snap_name} for host #{host}") unless vm.snapshots.data.include? snap_name

      logger.notify "Reverting #{host} to snapshot #{snap_name}"
      start = Time.now
      vm.revert_to_snapshot snap_name
      while vm.running?.data
        sleep 1
      end
      time = Time.now - start
      logger.notify "Spent %.2f seconds reverting" % time

      logger.notify "Resuming #{host}"
      start = Time.now
      vm.start :headless => true
      until vm.running?.data
        sleep 1
      end
      time = Time.now - start
      logger.notify "Spent %.2f seconds resuming VM" % time
    end
  elsif options[:vmrun] == 'blimpy'
    require 'rubygems'
    require 'blimpy'

    AMI = YAML.load_file('config/image_templates/ec2.yaml')["AMI"]
    if options[:type] =~ /pe/
      image_type = :pe
    else
      image_type = :foss
    end

    fleet = Blimpy.fleet do |fleet|
      hosts.each do |host|
        amitype = host['vmname'] || host['platform']
        amisize = host['amisize'] || 'm1.small'
        ami = AMI[amitype]
        fleet.add(:aws) do |ship|
          ship.name = host.name
          ship.ports = amiports(host)
          ship.image_id = ami[:image][image_type]
          ship.flavor = amisize
          ship.region = ami[:region]
          ship.username = 'root'
        end
      end
    end

    fleet.start

    # Configure our nodes to match the blimp fleet
    # Also generate hosts entries for the fleet, since we're iterating
    etc_hosts = "127.0.0.1\tlocalhost localhost.localdomain\n"
    fleet.ships.each do |ship|
      ship.wait_for_sshd
      name = ship.name
      host = hosts.select { |host| host.name == name }[0]
      host['ip'] = ship.dns
      on host, "hostname #{name}"
      on host, "ip a|awk '/g/{print$2}' | cut -d/ -f1 | head -1"
      ip = stdout.chomp
      domain = get_domain_name(host)
      etc_hosts += "#{ip}\t#{name}\t#{name}.#{domain}\n"
    end

    # Send our hosts information to the nodes
    on hosts, "echo '#{etc_hosts}' > /etc/hosts"

  elsif options[:vmrun]
    raise ArgumentError, "Invalid value for vmrun: #{options[:vmrun]}"
  else
    skip_test "Skipping revert VM step"
  end
