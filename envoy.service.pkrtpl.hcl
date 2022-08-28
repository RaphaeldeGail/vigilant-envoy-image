[Unit]
Description=The ENVOY proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
PIDFile=/run/envoy.pid
ExecStartPre=/bin/bash -c "${ENVOY_PATH} --mode validate -c ${ENVOY_CONFIGURATION_FILE} | tee"
ExecStart=/bin/bash -c "${ENVOY_PATH} -c ${ENVOY_CONFIGURATION_FILE} | tee"
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target