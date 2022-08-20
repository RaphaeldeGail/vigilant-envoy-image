#!/bin/bash

# Wait for APT updates to end
while  fuser /var/lib/dpkg/lock; do
   echo "waiting for external APT process to terminate..."
   sleep 5
done

if [ -z "$SERVER_KEY" ]; then
   echo "No private key SERVER_KEY found."
   exit 1
fi

if [ -z "$SERVER_CERT" ]; then
   echo "No public certificate SERVER_CERT found."
   exit 1
fi

echo "Loading certificate private key."
echo "$SERVER_KEY" > /etc/ssl/private/server.key
chown root:root /etc/ssl/private/server.key
chmod 400 /etc/ssl/private/server.key

echo "Loading certificate public key."
echo "$SERVER_CERT" > tee /etc/ssl/certs/server.pem
chown root:root /etc/ssl/certs/server.pem
chmod 600 /etc/ssl/certs/server.pem

if ! test -s /etc/ssl/private/server.key; then
   echo "Private key /etc/ssl/private/server.key was not correctly written."
   exit 1
fi
echo "Private key successfully loaded."

if ! test -s /etc/ssl/certs/server.pem; then
   echo "public certificate /etc/ssl/certs/server.pem was not correctly written."
   exit 1
fi
echo "Public key successfully loaded."

echo "Testing if public and private SSL keys match."
if ! [ "$(openssl rsa -noout -modulus -in s/etc/ssl/private/server.key | openssl md5)"=="$(openssl x509 -noout -modulus -in /etc/ssl/certs/server.pem | openssl md5)" ]; then
   echo "Public and private keys do not match."
   exit 1
fi
echo "Public and private keys match perfectly."

echo "Configuring envoy service to systemd."
cat | tee /etc/systemd/system/envoy.service > /dev/null <<EOF
[Unit]
Description=The ENVOY proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
PIDFile=/run/envoy.pid
ExecStartPre=/bin/bash -c '/usr/local/bin/envoy --mode validate -c /etc/envoy.yaml | tee'
ExecStart=/bin/bash -c '/usr/local/bin/envoy -c /etc/envoy.yaml | tee'
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chown root:root /etc/systemd/system/envoy.service
chmod 644 /etc/systemd/system/envoy.service

if ! test -s /etc/systemd/system/envoy.service; then
   echo "Service file /etc/systemd/system/envoy.service was not correctly written."
   exit 1
fi
echo "Service file envoy.service successfully loaded"

if ! systemctl daemon-reload; then
   echo "Sytemd could not read the envoy service file."
   exit 1
fi
if ! systemctl enable envoy; then
   echo "Systemd could not enable the envoy service at boot."
   exit 1
fi
echo "Envoy service was succesfully loaded into Systemd."

echo "Loading envoy default configuration file."
cat | tee /etc/envoy.yaml > /dev/null <<EOF
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
                  filename: /etc/ssl/certs/server.pem
                  private_key:
                  filename: /etc/ssl/private/server.key
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
chown root:root /etc/envoy.yaml
chmod 644 /etc/envoy.yaml

if ! test -s /etc/envoy.yaml; then
   echo "Configuration file /etc/envoy.yaml was not correctly written."
   exit 1
fi
echo "Configuration file /etc/envoy.yaml successfully loaded."

echo "Installing build tools for envoy."
DEBIAN_FRONTEND=noninteractive apt-get --quiet update
DEBIAN_FRONTEND=noninteractive apt-get --quiet -y install \
   autoconf \
   automake \
   cmake \
   curl \
   libtool \
   make \
   patch \
   unzip \
   python3-pip \
   virtualenv \
   ninja-build

if ! ninja --version; then
  echo 'Error could not find ninja builder'
  exit 1
fi

wget -qO /usr/local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/download/v1.12.0/bazelisk-linux-amd64
chmod +x /usr/local/bin/bazel

if ! bazel --version; then
  echo 'Error could not find bazel builder'
  exit 1
fi

curl -s -LO https://go.dev/dl/go1.18.3.linux-amd64.tar.gz
if [ -d /usr/local/go ]; then
   rm -rf /usr/local/go
fi
tar -C /usr/local -xzf go1.18.3.linux-amd64.tar.gz
rm -rf go1.18.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

if ! go version; then
  echo 'Error could not find go'
  exit 1
fi

go install github.com/bazelbuild/buildtools/buildifier@5.1.0
go install github.com/bazelbuild/buildtools/buildozer@5.1.0

echo "Building envoy."
if [ -d ./envoy ]; then
   rm -rf ./envoy
fi

git clone -q --branch v1.21.0 https://github.com/envoyproxy/envoy.git
cd envoy
bazel build envoy
if [ -x bazel-bin/source/exe/envoy-static ]; then
    mv bazel-bin/source/exe/envoy-static /usr/local/bin/envoy
fi
cd ..
rm -rf ./envoy
echo "Build terminated."

if ! envoy --version; then
  echo "Error could not find envoy."
  exit 1
fi

if ! /usr/local/bin/envoy --mode validate -c /etc/envoy.yaml; then
  echo "Error could not start with the default configuration."
  exit 1
fi

# Delete Cache from Build
rm -rf $HOME/.cache/bazel*
# Delete bazel tool
rm -rf /usr/local/bin/bazel
# Delete go pacakges
if [ -d /usr/local/go ]; then
   rm -rf /usr/local/go
fi
# Delete buildifier and buildozer
rm -rf $HOME/go/bin

echo "Estimate disk usage after cleaning"
df -h

echo "Installing simple Nginx server."
DEBIAN_FRONTEND=noninteractive apt-get --quiet update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get --quiet -y install nginx >/dev/null

if ! systemctl is-active nginx > /dev/null; then
   echo "Nginx service is not active."
   exit 1
fi
echo "Nginx service is active."

if ! [ $(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/') == 200 ]; then
   echo "Nginx HTTP service is not responding."
   exit 1
fi
echo "Nginx HTTP service is correctly responding."

# Disable APT sources
echo "Removing APT packages cache and lists."
apt-get --quiet clean >/dev/null
rm -rf /etc/apt/sources.list /etc/apt/sources.list.d/

# Disable APT auto updates
echo "Loading APT configuration to halt auto-update."
echo -ne "APT::Periodic::Update-Package-Lists \"0\";\nAPT::Periodic::Unattended-Upgrade \"0\";" > /etc/apt/apt.conf.d/20auto-upgrades
if ! test -s /etc/apt/apt.conf.d/20auto-upgrades; then
   echo "Configuration file /etc/apt/apt.conf.d/20auto-upgrades was not correctly written."
   exit 1
fi
echo "APT auto-update succesfully disabled."

echo -ne "\nBuild was succesful.\n"
exit 0