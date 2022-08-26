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
  project_id                      = var.workspace.project
  source_image_family             = var.machine.source_image_family
  disable_default_service_account = true
  communicator                    = "ssh"
  ssh_username                    = "packer-bot"
  zone                            = "${var.workspace.region}-b"
  skip_create_image               = var.skip_create_image

  image_name        = join("-", [var.workspace.name, "v{{ timestamp }}", var.machine.source_image_family])
  image_description = "Envoy customized image for HTTP service proxy, based on ${var.machine.source_image_family}"
  image_family      = join("-", [var.workspace.name, var.machine.source_image_family])


  machine_type     = "c2-standard-8"
  min_cpu_platform = "Intel Cascade Lake"
  network          = "${var.workspace.name}-network"
  subnetwork       = "${var.workspace.name}-subnet"
  tags             = [var.workspace.name]

  disk_size = 20
  disk_type = "pd-ssd"
}

build {
  name    = join("-", [var.workspace.name, "build", var.machine.source_image_family])
  sources = ["sources.googlecompute.custom"]

  provisioner "shell" {
    environment_vars = [
      "SERVER_CERT=${var.machine.certificate_keystore.public}",
      "SERVER_KEY=${var.machine.certificate_keystore.private}",
      "ENVOY_CONFIGURATION=${base64encode(file("envoy.yaml"))}"
    ]
    # Will execute the script as root
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    valid_exit_codes = [0]
    script           = "./script.sh"
  }
}