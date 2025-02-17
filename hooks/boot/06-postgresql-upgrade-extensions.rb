module PostgresqlUpgradeHookContextExtension
  def needs_postgresql_upgrade?(new_version)
    current_version.to_i < new_version.to_i
  rescue Errno::ENOENT
    false
  end

  def current_version
    File.read('/var/lib/pgsql/data/PG_VERSION').chomp
  end

  def os_needs_postgresql_upgrade?
    el8? && needs_postgresql_upgrade?(13)
  end

  def postgresql_upgrade(new_version)
    logger.notice("Performing upgrade of PostgreSQL to #{new_version}")

    stop_services

    logger.notice("Upgrading PostgreSQL packages")

    execute!("dnf module switch-to postgresql:#{new_version} -y", false, true)

    server_packages = ['postgresql', 'postgresql-server', 'postgresql-upgrade']
    ['postgresql-contrib', 'postgresql-docs'].each do |extra_package|
      if execute("rpm -q #{extra_package}", false, false)
        server_packages << extra_package
      end
    end

    ensure_packages(server_packages, 'latest')

    logger.notice("Migrating PostgreSQL data")

    # We need to know the collation and ctype of the DB as postgresql-setup --upgrade
    # doesn't detect those on its own: https://issues.redhat.com/browse/RHEL-58410
    # dnf switch-to has already replaced the packages and the cluster is down
    # We have to start the cluster in single-user mode with the old postgres binary
    postgres_result = `echo "select datcollate,datctype from pg_database where datname='postgres';" | runuser -l postgres -c '/usr/lib64/pgsql/postgresql-#{current_version}/bin/postgres --single -D /var/lib/pgsql/data postgres'`
    data = {}
    postgres_result.each_line do |line|
      line.match(/dat(collate|ctype)\s+=\s+(\S+)/) do |m|
        data[m[1]] = m[2].delete('"')
      end
    end
    collate = data['collate']
    ctype = data['ctype']

    # puppetlabs-postgresql always sets data_directory in the config
    # see https://github.com/puppetlabs/puppetlabs-postgresql/issues/1576
    # however, one can't use postgresql-setup --upgrade if that value is set
    # see https://bugzilla.redhat.com/show_bug.cgi?id=1935301
    execute!("sed -i '/^data_directory/d' /var/lib/pgsql/data/postgresql.conf", false, true)

    execute_as!('postgres', "PGSETUP_INITDB_OPTIONS=\"--lc-collate=#{collate} --lc-ctype=#{ctype} --locale=#{collate}\" postgresql-setup --upgrade", false, true)

    logger.notice("Analyzing the new PostgreSQL cluster")

    start_services(['postgresql'])

    execute_as!('postgres', 'vacuumdb --all --analyze-in-stages', false, true)

    logger.notice("Upgrade to PostgreSQL #{new_version} completed")
  end

  def check_postgresql_storage
    # Ensure there is at least 1x /var/lib/pgsql free disk space available on the main filesystem
    current_postgres_dir = '/var/lib/pgsql/data'
    new_postgres_dir = '/var/lib/pgsql'

    begin
      postgres_size = `du --bytes --summarize #{current_postgres_dir}`.split[0].to_i

      if available_space(new_postgres_dir) < postgres_size
        fail_and_exit "The PostgreSQL upgrade requires at least #{(postgres_size / 1024) / 1024} MB of storage to be available at #{new_postgres_dir}."
      end
    rescue StandardError
      fail_and_exit 'Failed to verify available disk space'
    end
  end
end

Kafo::HookContext.send(:include, PostgresqlUpgradeHookContextExtension)
