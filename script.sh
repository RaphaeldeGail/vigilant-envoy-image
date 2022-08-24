#!/bin/bash

# Define global shortcuts and variables

## Environment variables for executables
export DEBIAN_FRONTEND=noninteractive
export GOROOT='/usr/local/go'
export GOPATH="$HOME/go"

## Variables for script
OS_RELEASE_NAME=$(lsb_release -cs)
GO_URL='https://go.dev/dl/go1.18.3.linux-amd64.tar.gz'
BAZEL_URL='https://github.com/bazelbuild/bazelisk/releases/download/v1.12.0/bazelisk-linux-amd64'
BAZEL_PATH='/usr/local/bin/bazel'
SERVER_KEY_PATH='/etc/ssl/private/server.key'
SERVER_CERT_PATH='/etc/ssl/certs/server.pem'
LLVM_URL='apt.llvm.org'
LLVM_PKG='libllvm14 llvm-14 llvm-14-runtime clang-14 clang-tools-14 libclang1-14 clang-format-14 python3-clang-14 clangd-14 clang-tidy-14 lldb-14 lld-14 mlir-14-tools'
LLVM_PATH='/usr/lib/llvm-14/'
ENVOY_PATH='/usr/local/bin/envoy'
ENVOY_DIRECTORY='/etc/envoy'
ENVOY_CONFIGURATION_FILE="$ENVOY_DIRECTORY/envoy.yaml"
ENVOY_SERVICE_FILE='/etc/systemd/system/envoy.service'

get () {
   apt-get install -y -qq --no-show-upgraded $@ >/dev/null
   return $?
}

info () {
   echo "$(date) - $(hostname) - INFO - $*"
   return 0
}

error () {
   echo "$(date) - $(hostname) - ERROR - $*"
   echo "********** Build Failed. **********"
   exit 1
   return 1
}

# Set default umask for files created
umask 0022

info "Adding basic tools"
apt-get update -qq --no-show-upgraded >/dev/null
get git cmake ninja-build python3-distutils
info "Git: $(git --version)"
info "CMAKE: $(cmake --version | head -n 1)"
info "Ninja: $(ninja --version)"


info "Adding CLang/LLVM to APT repos."
curl -sL "https://$LLVM_URL/llvm-snapshot.gpg.key" | apt-key add -
echo "deb http://$LLVM_URL/$OS_RELEASE_NAME/ llvm-toolchain-$OS_RELEASE_NAME-14 main" > /etc/apt/sources.list.d/llvm.list

if ! apt-get update -qq --no-show-upgraded >/dev/null; then
   error "Could not update APT repos with CLang/LLVM."
fi
info "CLang/LLVM repos succesfully added to APT sources."

info "Installing CLang/LLVM."
get "$LLVM_PKG"
if ! [ -d $LLVM_PATH ]; then
   error "CLang/LLVM librairies not found were not found on path $LLVM_PATH."
fi
info "CLang/LLVM librairies succesfully installed on path $LLVM_PATH."


info "Installing Bazel."
RC=$(curl -sL -o $BAZEL_PATH -w '%{http_code}' "$BAZEL_URL")
if [ $RC != 200 ]; then
   error "Could not download Bazel from source : $BAZEL_URL."
fi
if ! [ -f $BAZEL_PATH ]; then
   error "Could not find Bazel binary file."
fi
chmod +x $BAZEL_PATH
if ! bazel --version; then
  error "Could not execute Bazel binary."
fi
info "Bazel succesfully installed."

info "Installing Go."
RC=$(curl -sL -o go.tar.gz -w '%{http_code}' "$GO_URL")
if [ $RC != 200 ]; then
   error "Could not download Go from source : $GO_URL."
fi
if [ -d $GOROOT ]; then
   rm -rf $GOROOT
fi
tar -C /usr/local -xzf go.tar.gz
rm -rf go.tar.gz
if ! [ -x $GOROOT/bin/go ]; then
   error "Could not find Go compiler."
fi
export PATH=$PATH:$GOROOT/bin
if ! go version; then
  error "Could not execute go compiler."
fi
info "Go successfully installed."

info "Installing Buildifier utility."
go install github.com/bazelbuild/buildtools/buildifier@5.1.0
info "Installing Buildozer utility."
go install github.com/bazelbuild/buildtools/buildozer@5.1.0

info "Building Envoy."
cd $HOME
if [ -d ./envoy ]; then
   rm -rf ./envoy
fi
git clone -q --branch v1.21.0 https://github.com/envoyproxy/envoy.git
cd envoy
bazel/setup_clang.sh $LLVM_PATH
bazel build --config=libc++ envoy
if [ -x bazel-bin/source/exe/envoy-static ]; then
   mv bazel-bin/source/exe/envoy-static $ENVOY_PATH
   chmod 555 $ENVOY_PATH
else
   error "Envoy did not compile."
fi
cd ..
rm -rf ./envoy
if ! envoy --version; then
  error "Could not execute Envoy binary."
fi
info "Build terminated : $(envoy --version | sed -e 's/envoy\(.*\)version:\(.*\)/\2/g')"


info "Clearing build temporary artifcats."
# Delete Cache from Build
rm -rf $HOME/.cache/
# Delete bazel tool
rm -rf $BAZEL_PATH
# Delete go pacakges
rm -rf $GOROOT
# Delete GOPATH directory
rm -rf $GOPATH
# Delete temporary directories
rm -rf /tmp/*
rm -rf /var/tmp/*

info "Estimating disk usage after cleaning"
df -h


info "Loading envoy default configuration file."
mkdir -p $ENVOY_DIRECTORY
cat >$ENVOY_CONFIGURATION_FILE <<EOF
static_resources:
   listeners:
   - name: main_listener
      address:
      socket_address:
         address: 0.0.0.0
         port_value: 443
      filter_chains:
      - filters:
      - name: envoy.filters.network.http_connection_manager
         typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            stat_prefix: ingress_http
            server_name: lab.wansho.fr
            preserve_external_request_id: true
            access_log:
            - name: envoy.access_loggers.stdout
            typed_config:
               "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
            http_filters:
            - name: envoy.filters.http.router
            typed_config:
               "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
            route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
               domains: ["*"]
               require_tls: ALL
               cors:
                  allow_methods: 'OPTION, GET'
               routes:
               - match:
                  prefix: "/"
                  route:
                  cluster: service_workstation
                  cluster_not_found_response_code: SERVICE_UNAVAILABLE
      transport_socket:
         name: envoy.transport_sockets.tls
         typed_config:
            "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
            common_tls_context:
            alpn_protocols: ["h2"]
            tls_certificates:
               - certificate_chain:
                  filename: $SERVER_CERT_PATH
                  private_key:
                  filename: $SERVER_KEY_PATH
   clusters:
   - name: service_workstation
      type: LOGICAL_DNS
      # Comment out the following line to test on v6 networks
      dns_lookup_family: V4_ONLY
      lb_policy: ROUND_ROBIN
      load_assignment:
      cluster_name: service_workstation
      endpoints:
      - lb_endpoints:
         - endpoint:
            address:
               socket_address:
                  address: 10.1.0.2
                  port_value: 443
EOF

if ! test -s $ENVOY_CONFIGURATION_FILE; then
   error "Envoy default configuration file was not correctly written to $ENVOY_CONFIGURATION_FILE."
fi
info "Envoy default configuration file successfully written to $ENVOY_CONFIGURATION_FILE."


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

info "Testing envoy configuration file."
if ! $ENVOY_PATH --mode validate -c $ENVOY_CONFIGURATION_FILE; then
  error "Could not start with the default configuration."
fi
info "Envoy configuration file is correct."


info "Configuring envoy service to systemd."
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
ExecStop=/bin/kill -s QUIT $MAINPID
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
info "Envoy service is active."


info "Installing simple Nginx server."
apt-get update -qq --no-show-upgraded >/dev/null
get nginx

sleep 10

if ! systemctl is-active nginx > /dev/null; then
   error "Nginx service is not active."
fi
info "Nginx service is active."

if [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/')" != "200" ]; then
   error "Nginx HTTP service is not responding."
fi
info "Nginx HTTP service is correctly responding."

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

echo "********** Build was succesful. **********"
exit 0