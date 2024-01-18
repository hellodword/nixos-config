{ pkgs, inputs, ... }:

{
  security.auditd.enable = true;
  security.audit.enable = true;

  # http://security-plus-data-science.blogspot.com/2017/05/a-suggested-change-for-rhel-7-disa-stig.html
  # fix audit: kauditd hold queue overflow
  boot.kernelParams = [ "audit_backlog_limit=8192" ];

  environment.etc = {
    "audit/audit.rules" = {
      enable = true;
      source = "${inputs.auditd-rules}/audit.rules";
    };
    "audit/auditd.conf" = {
      enable = true;
      text = ''
        #
        # This file controls the configuration of the audit daemon
        #

        local_events = yes
        write_logs = yes
        log_file = /var/log/audit/audit.log
        log_group = adm
        log_format = ENRICHED
        flush = INCREMENTAL_ASYNC
        freq = 50
        max_log_file = 8
        num_logs = 5
        priority_boost = 4
        name_format = NONE
        ##name = mydomain
        max_log_file_action = ROTATE
        space_left = 75
        space_left_action = SYSLOG
        verify_email = yes
        action_mail_acct = root
        admin_space_left = 50
        admin_space_left_action = SUSPEND
        disk_full_action = SUSPEND
        disk_error_action = SUSPEND
        use_libwrap = yes
        ##tcp_listen_port = 60
        tcp_listen_queue = 5
        tcp_max_per_addr = 1
        ##tcp_client_ports = 1024-65535
        tcp_client_max_idle = 0
        transport = TCP
        krb5_principal = auditd
        distribute_network = no
        q_depth = 1200
        overflow_action = SYSLOG
        max_restarts = 10
        end_of_event_timeout = 2
      '';
    };
  };

  # /var/log
  # environment.persistence = {
  #   "${persistPath}".directories = [
  #     "/var/log/audit/audit"
  #   ];
  # };
}
