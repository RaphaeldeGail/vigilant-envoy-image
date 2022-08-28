packer {
  required_version = ">= 1.8.0"
  required_plugins {
    googlecompute = {
      version = "~> 1.0.10"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

source "googlecompute" "custom" {
  project_id            = var.workspace.project
  source_image_family   = var.machine.source_image_family
  service_account_email = "main-lab-v1-executables-reader@lab-v1-0hw3q17w6a1y30jo-a5114.iam.gserviceaccount.com"
  communicator          = "ssh"
  ssh_username          = "packer-bot"
  zone                  = "${var.workspace.region}-b"
  skip_create_image     = var.skip_create_image
  instance_name         = join("-", [var.workspace.name, "v{{ timestamp }}", var.machine.source_image_family])

  image_name        = join("-", [var.workspace.name, "v{{ timestamp }}", var.machine.source_image_family])
  image_description = "Envoy customized image for HTTP service proxy, based on ${var.machine.source_image_family}"
  image_family      = join("-", [var.workspace.name, var.machine.source_image_family])


  machine_type = "e2-micro"
  network      = "${var.workspace.name}-network"
  subnetwork   = "${var.workspace.name}-subnet"
  tags         = [var.workspace.name]

  disk_size = 10
  disk_type = "pd-standard"
}

locals {
  server_key_path          = "/etc/ssl/private/${var.workspace.name}.key"
  server_cert_path         = "/etc/ssl/certs/${var.workspace.name}.pem"
  envoy_path               = "/usr/local/bin/${var.workspace.name}"
  envoy_directory          = "/etc/${var.workspace.name}"
  envoy_configuration      = base64encode(templatefile("envoy.yaml.pkrtpl.hcl", { SERVER_KEY_PATH = local.server_key_path, SERVER_CERT_PATH = local.server_cert_path }))
  envoy_configuration_file = "${local.envoy_directory}/default.yaml"
  envoy_service            = base64encode(templatefile("envoy.service.pkrtpl.hcl", { ENVOY_PATH = local.envoy_path, ENVOY_CONFIGURATION_FILE = local.envoy_configuration_file }))
}

build {
  name    = join("-", [var.workspace.name, "builder", var.machine.source_image_family])
  sources = ["sources.googlecompute.custom"]

  provisioner "shell" {
    environment_vars = [
      "SERVER_CERT=${var.machine.certificate_keystore.public}",
      "SERVER_KEY=${var.machine.certificate_keystore.private}",
      "NAME=${var.workspace.name}",
      "SERVER_KEY_PATH=${local.server_key_path}",
      "SERVER_CERT_PATH=${local.server_cert_path}",
      "ENVOY_CONFIGURATION=${local.envoy_configuration}",
      "ENVOY_PATH=${local.envoy_path}",
      "ENVOY_DIRECTORY=${local.envoy_directory}",
      "ENVOY_CONFIGURATION_FILE=${local.envoy_configuration_file}",
      "ENVOY_SERVICE=${local.envoy_service}",
      "ENVOY_SERVICE_FILE=/etc/systemd/system/${var.workspace.name}.service"
    ]
    # Will execute the script as root
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    valid_exit_codes = [0]
    script           = "./script.sh"
  }
}