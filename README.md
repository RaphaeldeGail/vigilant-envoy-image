# vigilant-envoy-image

This code builds a GCE image for a stateless envoy server with the help of packer.

## Build description

An image is built upon a DEBIAN based OS on Google Cloud.
The relying instance is e2-type VM with no specific attributes (GPU, processor acrchitecture, etc.).
The image is built over the instance with a provisioning shell script that:

- Add specific SSL keys sor the envoy server TLS stream
- Add a default configuration for envoy
- Install a simple Nginx server on port 80 for HTTP health checks
- Sets up a service to control envoy with systemd

This image is intended for usage on HTTP proxy servicing.

## Usage

Set the values of the required variables, either in a file or with environment variables.

Authenticate to Google Cloud Platform with a relevant account or set the environment variable **GOOGLE\_APPLICATION\_CREDENTIALS** to the path of a JSON service account key.

Simply run:

```bash
packer init .
packer build .
```

with appropriate options.

## Requirements

| Name | Version |
|------|---------|
| packer | >= 1.8.0 |
| googlecompute | ~> 1.0.10 |

## Builds

| Name | Type |
|------|------|
| [googlecompute.custom](https://www.packer.io/plugins/builders/googlecompute) | source |
| [build.provisioner.shell](https://www.packer.io/docs/provisioners/shell) | provisioner |

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| workspace | The workspace that will be used on GCP to build the image. Requires the **name** of the build (e.g \"bounce\"), the ID of a GCP **project** and the **region** of deployment on GCP. The **name** attributes must contain only lowercase letters. The **project** attribute can not be empty. | ```object({ name = string project = string region = string })``` | n/a |
| machine | The machine that will be used to create the packer image. Requires a **source_image_family** in GCP format and a **certificate_keystore** with both **private** and **public** SSL keys base64 encoded. The **source_image_family** attribute can not be empty. | ```object({ source_image_family = string certificate_keystore = object({ private = string public  = string }) })``` | n/a |
| skip_create_image | If true, packer does not create an image from the built disk. | bool | true |
