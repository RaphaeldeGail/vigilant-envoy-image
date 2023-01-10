#!/bin/bash

# Define global shortcuts and variables
## Environment variables for executables
export DEBIAN_FRONTEND=noninteractive

# Define functions
repo_get () {
   RC=$( apt-get install -y $@ )
   if [ $? != 0 ]; then
      error "Failed to install the following packages $*.\n$RC"
      return 1
   fi
   return 0
}

repo_update () {
   RC=$(apt-get update)
   if [ $? != 0 ]; then
      error "Failed to synchronize with distant repositories.\n$RC"
      return 1
   fi
   return 0
}

info () {
   echo "[$(date -I'seconds')][$(hostname)][INFO] : $*"
   return 0
}

error () {
   echo -e "[$(date -I'seconds')][$(hostname)][ERROR] : $*" >&2
   echo "********** Build Failed. **********" >&2
   exit 1
   return 0
}

envoy_config () {
   info "Loading envoy default configuration file."
   mkdir -p $ENVOY_DIRECTORY
   echo -n "$ENVOY_CONFIGURATION" | base64 --decode >$ENVOY_CONFIGURATION_FILE
   if ! test -s $ENVOY_CONFIGURATION_FILE; then
      error "Envoy default configuration file was not correctly written to $ENVOY_CONFIGURATION_FILE."
      return 1
   fi
   info "Envoy default configuration file successfully written to $ENVOY_CONFIGURATION_FILE."
   return 0
}

ssl_config () {
   info "Adding server SSL private key."
   if [ -z "$SERVER_KEY" ]; then
      error "The environment variable SERVER_KEY is empty."
   fi
   echo -n "$SERVER_KEY" | base64 --decode >$SERVER_KEY_PATH
   chmod 400 $SERVER_KEY_PATH
   if ! test -s $SERVER_KEY_PATH; then
      error "The server SSL private key was not correctly written on file $SERVER_KEY_PATH."
   fi
   info "Server SSL private key successfully written on file $SERVER_KEY_PATH."

   info "Adding server SSL certificate."
   if [ -z "$SERVER_CERT" ]; then
      error "No public certificate SERVER_CERT found."
   fi
   echo -n "$SERVER_CERT" | base64 --decode >$SERVER_CERT_PATH
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

   info "SSL keys succesfully loaded."
   return 0
}

install_requirements () {
   info "Installing Bazel."
   BAZELISK_VERSION="v1.14.0"
   BAZELISK_URL="https://github.com/bazelbuild/bazelisk/releases/download/$BAZELISK_VERSION/bazelisk-linux-amd64"
   curl -sL "$BAZELISK_URL" -o /usr/local/bin/bazel
   chmod +x /usr/local/bin/bazel
   RC=$(bazel version)
   if [ $? != 0 ]; then
      error "Failed to install Bazel.\n$RC"
      return 1
   fi
   info "Bazel successfully installed."

   info "Installing LLVM packages."
   KEYRING='/etc/apt/trusted.gpg.d/llvm.gpg'
   VERSION="14"
   curl -s https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor > $KEYRING
   cat <<EOF > /etc/apt/sources.list.d/llvm.list
deb [signed-by=$KEYRING] http://apt.llvm.org/bullseye/ llvm-toolchain-bullseye-$VERSION main
deb-src [signed-by=$KEYRING] http://apt.llvm.org/bullseye/ llvm-toolchain-bullseye-$VERSION main
EOF

   repo_update
   # All standard LLVM packages
   repo_get libllvm-$VERSION-ocaml-dev libllvm$VERSION llvm-$VERSION llvm-$VERSION-dev llvm-$VERSION-doc llvm-$VERSION-examples llvm-$VERSION-runtime
   repo_get clang-$VERSION clang-tools-$VERSION clang-$VERSION-doc libclang-common-$VERSION-dev libclang-$VERSION-dev libclang1-$VERSION clang-format-$VERSION python3-clang-$VERSION clangd-$VERSION clang-tidy-$VERSION
   repo_get libfuzzer-$VERSION-dev
   repo_get lldb-$VERSION
   repo_get lld-$VERSION
   repo_get libc++-$VERSION-dev libc++abi-$VERSION-dev
   repo_get libomp-$VERSION-dev
   repo_get libclc-$VERSION-dev
   repo_get libunwind-$VERSION-dev
   repo_get libmlir-$VERSION-dev mlir-$VERSION-tools

   if ! [ -d /usr/lib/llvm-$VERSION ]; then
      error "LLVM root directory does not seem to exists : /usr/lib/llvm-$VERSION ."
      return 1
   fi
   RC=$(clang-$VERSION --version)
   if [ $? != 0 ]; then 
      error "LLVM/Clang compilator does not seem to work.\n$RC"
      return 1
   fi
   info "LLVM packages successfully installed."

   info "Installing miscaneleous required packages."
   # Miscaneleous tools to compile envoy with bazel
   repo_get git autoconf automake cmake curl libtool make ninja-build patch python3-pip unzip virtualenv
   info "Miscaneleous packages succesfully installed."

   return 0
}

build_envoy() {
   info "Compiling envoy."
   VERSION="14"
   git clone -b v1.24.0 https://github.com/envoyproxy/envoy.git
   cd envoy
   bazel/setup_clang.sh /usr/lib/llvm-$VERSION
   echo "build --config=clang" >> user.bazelrc
   bazel build --verbose_failures -c opt envoy
   cp bazel-bin/source/exe/envoy-static /usr/local/bin/envoy

   if ! envoy --version; then
      error "Could not execute Envoy binary."
      return 1
   fi
   info "Envoy successfully compiled."

   return 0
}

install_envoy () {
   info "Downloading Envoy binary."
   gsutil -q cp gs://main-lab-v1-executables/envoy-v1.21.0 $ENVOY_PATH
   chmod 555 $ENVOY_PATH
   if ! envoy --version; then
      error "Could not execute Envoy binary."
   fi
   info "Envoy binary succesfully download."

   info "Testing envoy configuration."
   if ! $ENVOY_PATH --mode validate -c $ENVOY_CONFIGURATION_FILE 2>&1; then
      error "Could not start Envoy with the default configuration."
   fi

   info "Envoy is correctly configured."
   return 0
}

start_envoy () {
   echo -n "$ENVOY_SERVICE" | base64 --decode >$ENVOY_SERVICE_FILE

   if ! test -s $ENVOY_SERVICE_FILE; then
      error "Service file $ENVOY_SERVICE_FILE was not correctly written."
   fi
   info "Service file $ENVOY_SERVICE_FILE successfully written."

   info "Reloading the systemd service."
   if ! systemctl daemon-reload; then
      error "Sytemd could not read the envoy service file."
   fi
   if ! systemctl enable envoy 2>&1; then
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
   info "Envoy started."

   sleep 10

   info "Testing if Envoy HTTP proxy service is responding."
   if [ "$(curl -k -s -o /dev/null -w '%{http_code}' 'https://127.0.0.1:443/')" != "200" ]; then
      error "Envoy HTTP proxy service is not responding."
   fi
   info "Envoy HTTP proxy service is correctly responding."
   return 0
}

install_nginx () {
   info "Installing Nginx package."
   repo_update
   repo_get nginx
   info "Nginx package successfully installed."

   if ! systemctl is-active nginx > /dev/null; then
      error "Nginx service is not active."
   fi
   info "Nginx service is active."

   if [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/')" != "200" ]; then
      error "Nginx HTTP service is not responding."
   fi
   info "Nginx HTTP service is correctly responding."

   info "Nginx default backend is up and running."
   return 0
}

post_install () {
   # Disable APT sources
   info "Removing APT packages cache and lists."
   apt-get autoremove -qq -y >/dev/null
   apt-get clean -qq >/dev/null
   rm -f /etc/apt/sources.list.d/llvm.list

   # Disable APT auto updates
   info "Loading APT configuration to halt auto-update."
   echo -ne "APT::Periodic::Update-Package-Lists \"0\";\nAPT::Periodic::Unattended-Upgrade \"0\";" > /etc/apt/apt.conf.d/20auto-upgrades
   if ! test -s /etc/apt/apt.conf.d/20auto-upgrades; then
      error "Configuration file /etc/apt/apt.conf.d/20auto-upgrades was not correctly written."
   fi
   info "APT auto-update succesfully disabled."
   return 0
}

main () {
   # envoy_config
   # ssl_config
   # install_envoy
   # start_envoy

   install_nginx

   install_requirements

   build_envoy

   post_install

   return 0
} 

echo "********** START **********"

# Set default umask for files created
umask 0022

# Ensure to disable u-u to prevent breaking later
systemctl mask unattended-upgrades.service
systemctl stop unattended-upgrades.service
# Ensure process is in fact off:
info "Ensuring unattended-upgrades is disabled."
while systemctl is-active --quiet unattended-upgrades.service; do sleep 1; done
info "unattended-upgrades service is inactive."

# Main function
main

echo "********** Build was succesful. **********"
exit 0