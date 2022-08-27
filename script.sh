#!/bin/bash

# Define global shortcuts and variables

## Environment variables for executables
export DEBIAN_FRONTEND=noninteractive

## Variables for script
ENVOY_PATH='/usr/local/bin/envoy'
ENVOY_DIRECTORY='/etc/envoy'
ENVOY_CONFIGURATION_FILE="$ENVOY_DIRECTORY/envoy.yaml"
ENVOY_SERVICE_FILE='/etc/systemd/system/envoy.service'

get () {
   apt-get install -y -qq --no-show-upgraded $@ 1>/dev/null
   return $?
}

info () {
   echo "$(date) - $(hostname) - [INFO] - $*"
   return 0
}

error () {
   echo "$(date) - $(hostname) - [ERROR] - $*" >&2
   echo "********** Build Failed. **********" >&2
   exit 1
   return 1
}

envoy_config () {
   mkdir -p $ENVOY_DIRECTORY
   echo -ne "$ENVOY_CONFIGURATION" | base64 --decode >$ENVOY_CONFIGURATION_FILE

   if ! test -s $ENVOY_CONFIGURATION_FILE; then
      error "Envoy default configuration file was not correctly written to $ENVOY_CONFIGURATION_FILE."
   fi
   cat $ENVOY_CONFIGURATION_FILE
   return 0
}

ssl_keys () {
   info "Adding server SSL private key."
   if [ -z "$SERVER_KEY" ]; then
      error "The environment variable SERVER_KEY is empty."
   fi
   echo -n "$SERVER_KEY" | base64 --decode > "$SERVER_KEY_PATH"
   chmod 400 "$SERVER_KEY_PATH"
   if ! test -s "$SERVER_KEY_PATH"; then
      error "The server SSL private key was not correctly written on file $SERVER_KEY_PATH."
   fi
   info "Server SSL private key successfully written on file $SERVER_KEY_PATH."

   info "Adding server SSL certificate."
   if [ -z "$SERVER_CERT" ]; then
      error "No public certificate SERVER_CERT found."
   fi
   echo -n "$SERVER_CERT" | base64 --decode > $SERVER_CERT_PATH
   chmod 600 $SERVER_CERT_PATH
   if ! test -s $SERVER_CERT_PATH; then
      error "The server SSL certificate was not correctly written on file $SERVER_CERT_PATH."
   fi
   info "Server SSL certificate successfully written on file $SERVER_CERT_PATH."

   info "Testing if public and private SSL keys of server match."
   if ! [ "$(openssl rsa -noout -modulus -in $SERVER_KEY_PATH | openssl md5)"=="$(openssl x509 -noout -modulus -in $SERVER_CERT_PATH | openssl md5)" ]; then
      error "Public and private SSL keys of server do not match."
   fi
   info "Public and private SSL keys of server match."
   return 0
}

install () {
   gsutil cp gs://main-lab-v1-executables/envoy-v1.21.0 $ENVOY_PATH
   chmod 555 $ENVOY_PATH
   if ! envoy --version; then
      error "Could not execute Envoy binary."
   fi
   return 0
}

test_envoy () {
   if ! $ENVOY_PATH --mode validate -c $ENVOY_CONFIGURATION_FILE; then
   error "Could not start with the default configuration."
   fi
   return 0
}

start_envoy () {
cat >$ENVOY_SERVICE_FILE <<EOF
   [Unit]
   Description=The ENVOY proxy server
   After=syslog.target network-online.target remote-fs.target nss-lookup.target
   Wants=network-online.target

   [Service]
   Type=simple
   PIDFile=/run/envoy.pid
   ExecStartPre=/bin/bash -c "$ENVOY_PATH --mode validate -c $ENVOY_CONFIGURATION_FILE | tee"
   ExecStart=/bin/bash -c "$ENVOY_PATH -c $ENVOY_CONFIGURATION_FILE | tee"
   ExecStop=/bin/kill -s QUIT \$MAINPID
   PrivateTmp=true

   [Install]
   WantedBy=multi-user.target
EOF

   if ! test -s $ENVOY_SERVICE_FILE; then
      error "Service file $ENVOY_SERVICE_FILE was not correctly written."
   fi
   info "Service file $ENVOY_SERVICE_FILE successfully written."

   info "Reloading the systemd service."
   if ! systemctl daemon-reload; then
      error "Sytemd could not read the envoy service file."
   fi
   if ! systemctl enable envoy; then
      error "Systemd could not enable the envoy service at boot."
   fi
   info "Envoy service was succesfully loaded into systemd."

   info "Starting envoy."
   if ! systemctl start envoy; then
      error "Envoy failed to start as a service."
   fi
   if ! systemctl is-active envoy > /dev/null; then
      error "Envoy service is not active."
   fi
   return 0
}

install_nginx () {
   apt-get update -qq --no-show-upgraded 1>/dev/null
   get nginx

   sleep 10

   if ! systemctl is-active nginx > /dev/null; then
      error "Nginx service is not active."
   fi
   info "Nginx service is active."

   if [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/')" != "200" ]; then
      error "Nginx HTTP service is not responding."
   fi
   return 0
}

post_install () {
   # Disable APT sources
   info "Removing APT packages cache and lists."
   apt-get autoremove -qq -y >/dev/null
   apt-get clean -qq >/dev/null
   rm -rf /etc/apt/sources.list /etc/apt/sources.list.d/

   # Disable APT auto updates
   info "Loading APT configuration to halt auto-update."
   echo -ne "APT::Periodic::Update-Package-Lists \"0\";\nAPT::Periodic::Unattended-Upgrade \"0\";" > /etc/apt/apt.conf.d/20auto-upgrades
   if ! test -s /etc/apt/apt.conf.d/20auto-upgrades; then
      error "Configuration file /etc/apt/apt.conf.d/20auto-upgrades was not correctly written."
   fi
   if ! apt-get update -qq --no-show-upgraded >/dev/null; then
      error "APT tool is wrongly configured."
   fi
   info "APT auto-update succesfully disabled."
   retrun 0
}

main () {
   info "Loading envoy default configuration file."
   envoy_config
   info "Envoy default configuration file successfully written to $ENVOY_CONFIGURATION_FILE."

   info "Loading SSL keys."
   ssl_keys
   info "SSL keys succesfully loaded."

   info "Install envoy executable."
   install
   info "Envoy executable succesfully installed."

   info "Testing envoy configuration."
   test_envoy
   info "Envoy configuration is correct."

   info "Starting Envoy as a service."
   start_envoy
   info "Envoy succesfully started as a service."

   info "Installing simple Nginx server."
   install_nginx
   info "Nginx HTTP service is correctly responding."

   info "Post installation tasks."
   post_install
   info "Post installation tasks succesfully ended."
   return 0
} 

# Set default umask for files created
umask 0022

main

echo "********** Build was succesful. **********"
exit 0