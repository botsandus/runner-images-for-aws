packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "ami_name" {
  type    = string
  default = "${env("AMI_NAME")}"
}

variable "ami_description" {
  type    = string
  default = "${env("AMI_DESCRIPTION")}"
}

variable "dockerhub_login" {
  type    = string
  default = "${env("DOCKERHUB_LOGIN")}"
}

variable "dockerhub_password" {
  type    = string
  default = "${env("DOCKERHUB_PASSWORD")}"
}

variable "helper_script_folder" {
  type    = string
  default = "/imagegeneration/helpers"
}

variable "imagedata_file" {
  type    = string
  default = "/imagegeneration/imagedata.json"
}

variable "image_folder" {
  type    = string
  default = "/imagegeneration"
}

variable "image_os" {
  type    = string
  // ex: ubuntu22
  default = "${env("IMAGE_OS")}"
}

variable "image_version" {
  type    = string
  default = "${env("IMAGE_VERSION")}"
}

variable "installer_script_folder" {
  type    = string
  default = "/imagegeneration/installers"
}

variable "region" {
  type    = string
  default = "${env("AWS_DEFAULT_REGION")}"
}

variable "ami_regions" {
  type    = list(string)
}

variable "source_ami_owner" {
  type    = string
  default = "099720109477"
}

variable "source_ami_name" {
  type    = string
  default = "ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"
}

// make sure the subnet auto-assigns public IPs
variable "subnet_id" {
  type    = string
  default = "${env("SUBNET_ID")}"
}

variable "volume_size" {
  type    = number
  default = 30
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

source "amazon-ebs" "build_ebs" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = "${var.ami_name}"
  ami_description                           = "${var.ami_description}"
  ami_virtualization_type                   = "hvm"
  # make AMIs publicly accessible
  # ami_groups                                = ["all"]
  ebs_optimized                             = true
  instance_type                             = "m7i-flex.large"
  region                                    = "${var.region}"
  ssh_username                              = "ubuntu"
  subnet_id                                 = "${var.subnet_id}"
  associate_public_ip_address               = "true"
  force_deregister                          = "true"
  force_delete_snapshot                     = "true"

  ami_regions = "${var.ami_regions}"

  // make underlying snapshot public
  # snapshot_groups = ["all"]

  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_type = "${var.volume_type}"
    volume_size = "${var.volume_size}"
    delete_on_termination = "true"
    iops = 3000
    throughput = 750
    encrypted = "false"
  }

  run_tags = {
    creator     = "RunsOn"
    contact     = "ops@runs-on.com"
    ami_name    = "${var.ami_name}"
  }

  tags = {
    creator     = "RunsOn"
    contact     = "ops@runs-on.com"
  }

  snapshot_tags = {
    creator     = "RunsOn"
    contact     = "ops@runs-on.com"
  }

  source_ami_filter {
    filters = {
      virtualization-type = "hvm"
      name                = "${var.source_ami_name}"
      root-device-type    = "ebs"
    }
    owners      = ["${var.source_ami_owner}"]
    most_recent = true
  }
}
build {
  
  sources = ["source.amazon-ebs.build_ebs"]

  provisioner "shell" {
    execute_command     = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts             = ["${path.root}/../custom/files/pre.sh"]
  }

  # Dummy file added to please Azure script compatibility
  provisioner "file" {
    destination = "/tmp/waagent.conf"
    source      = "${path.root}/../custom/files/waagent.conf"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mv /tmp/waagent.conf /etc"]
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mkdir ${var.image_folder}", "chmod 777 ${var.image_folder}"]
  }

  provisioner "file" {
    destination = "${var.helper_script_folder}"
    source      = "${path.root}/../scripts/helpers"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../scripts/build/configure-apt-mock.sh"
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}","DEBIAN_FRONTEND=noninteractive"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = [
      "${path.root}/../scripts/build/install-ms-repos.sh",
      "${path.root}/../scripts/build/configure-apt-sources.sh",
      "${path.root}/../scripts/build/configure-apt.sh"
    ]
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../scripts/build/configure-limits.sh"
  }

  provisioner "file" {
    destination = "${var.installer_script_folder}"
    source      = "${path.root}/../scripts/build"
  }

  provisioner "file" {
    destination = "${var.image_folder}"
    sources     = [
      "${path.root}/../assets/post-gen",
      "${path.root}/../scripts/tests",
      "${path.root}/../scripts/docs-gen"
    ]
  }

  provisioner "file" {
    destination = "${var.image_folder}/docs-gen/"
    source      = "${path.root}/../../../helpers/software-report-base"
  }

  provisioner "file" {
    destination = "${var.installer_script_folder}/toolset.json"
    source      = "${path.root}/../toolsets/toolset-2404.json"
  }

  provisioner "file" {
    destination = "${var.installer_script_folder}/toolset-patch.json"
    source      = "${path.root}/../custom/files/toolset-2404-patch.json"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = [
      "mv ${var.image_folder}/docs-gen ${var.image_folder}/SoftwareReport",
      "mv ${var.image_folder}/post-gen ${var.image_folder}/post-generation"
    ]
  }

  provisioner "shell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGEDATA_FILE=${var.imagedata_file}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/configure-image-data.sh"]
  }

  provisioner "shell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_OS=${var.image_os}", "HELPER_SCRIPTS=${var.helper_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/configure-environment.sh"]
  }

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive", "HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-apt-vital.sh"]
  }

provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-powershell.sh"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} pwsh -f {{ .Path }}'"
    // scripts          = ["${path.root}/../scripts/build/Install-PowerShellModules.ps1", "${path.root}/../scripts/build/Install-PowerShellAzModules.ps1"]
    scripts          = ["${path.root}/../scripts/build/Install-PowerShellModules.ps1"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}", "DEBIAN_FRONTEND=noninteractive"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = [
      // "${path.root}/../scripts/build/install-actions-cache.sh",
      "${path.root}/../scripts/build/install-runner-package.sh",
      "${path.root}/../scripts/build/install-apt-common.sh",
      "${path.root}/../scripts/build/install-azcopy.sh",
      "${path.root}/../scripts/build/install-azure-cli.sh",
      // "${path.root}/../scripts/build/install-azure-devops-cli.sh",
      # "${path.root}/../scripts/build/install-bicep.sh",
      # "${path.root}/../scripts/build/install-apache.sh",
      "${path.root}/../scripts/build/install-aws-tools.sh",
      "${path.root}/../scripts/build/install-clang.sh",
      "${path.root}/../scripts/build/install-cmake.sh",
      // "${path.root}/../scripts/build/install-codeql-bundle.sh",
      // "${path.root}/../scripts/build/install-container-tools.sh",
      # "${path.root}/../scripts/build/install-dotnetcore-sdk.sh",
      "${path.root}/../scripts/build/install-gcc-compilers.sh",
      "${path.root}/../scripts/build/install-gfortran.sh",
      "${path.root}/../scripts/build/install-git.sh",
      "${path.root}/../scripts/build/install-git-lfs.sh",
      "${path.root}/../scripts/build/install-github-cli.sh",
      # "${path.root}/../scripts/build/install-google-chrome.sh",
      // "${path.root}/../scripts/build/install-haskell.sh",
      # "${path.root}/../scripts/build/install-java-tools.sh",
      # "${path.root}/../scripts/build/install-kubernetes-tools.sh",
      # "${path.root}/../scripts/build/install-miniconda.sh",
      # "${path.root}/../scripts/build/install-mysql.sh",
      // "${path.root}/../scripts/build/install-nginx.sh",
      "${path.root}/../scripts/build/install-nodejs.sh",
      // "${path.root}/../scripts/build/install-bazel.sh",
      // "${path.root}/../scripts/build/install-php.sh",
      # "${path.root}/../scripts/build/install-postgresql.sh",
      // "${path.root}/../scripts/build/install-pulumi.sh",
      "${path.root}/../scripts/build/install-ruby.sh",
      "${path.root}/../scripts/build/install-rust.sh",
      // "${path.root}/../scripts/build/install-julia.sh",
      # "${path.root}/../scripts/build/install-selenium.sh",
      // "${path.root}/../scripts/build/install-vcpkg.sh",
      "${path.root}/../scripts/build/configure-dpkg.sh",
      "${path.root}/../scripts/build/install-yq.sh",
      // "${path.root}/../scripts/build/install-android-sdk.sh",
      "${path.root}/../scripts/build/install-pypy.sh",
      "${path.root}/../scripts/build/install-python.sh",
      "${path.root}/../scripts/build/install-zstd.sh"
    ]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}", "DOCKERHUB_PULL_IMAGES=NO"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-docker.sh"]
  }

provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../custom/files/install-nvidia-driver.sh"]
  }

provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../custom/files/install-nvidia-container.sh"]
  }

  // provisioner "shell" {
  //   environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
  //   execute_command  = "sudo sh -c '{{ .Vars }} pwsh -f {{ .Path }}'"
  //   scripts          = ["${path.root}/../scripts/build/Install-Toolset.ps1", "${path.root}/../scripts/build/Configure-Toolset.ps1"]
  // }

  // provisioner "shell" {
  //   environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
  //   execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  //   scripts          = ["${path.root}/../scripts/build/install-pipx-packages.sh"]
  // }

  // provisioner "shell" {
  //   environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "DEBIAN_FRONTEND=noninteractive", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
  //   execute_command  = "/bin/sh -c '{{ .Vars }} {{ .Path }}'"
  //   scripts          = ["${path.root}/../scripts/build/install-homebrew.sh"]
  // }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/configure-snap.sh"]
  }

  provisioner "shell" {
    execute_command     = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts             = ["${path.root}/../custom/files/runner-user.sh"]
  }

  provisioner "shell" {
    execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    inline            = ["echo 'Reboot VM'", "sudo reboot"]
  }

  provisioner "shell" {
    execute_command     = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    pause_before        = "1m0s"
    scripts             = ["${path.root}/../scripts/build/cleanup.sh", "${path.root}/../custom/files/after-reboot.sh"]
    start_retry_timeout = "10m"
  }

  // provisioner "shell" {
  //   environment_vars = ["IMAGE_VERSION=${var.image_version}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
  //   inline           = ["pwsh -File ${var.image_folder}/SoftwareReport/Generate-SoftwareReport.ps1 -OutputDirectory ${var.image_folder}", "pwsh -File ${var.image_folder}/tests/RunAll-Tests.ps1 -OutputDirectory ${var.image_folder}"]
  // }

  // provisioner "file" {
  //   destination = "${path.root}/../Ubuntu2404-Readme.md"
  //   direction   = "download"
  //   source      = "${var.image_folder}/software-report.md"
  // }

  // provisioner "file" {
  //   destination = "${path.root}/../software-report.json"
  //   direction   = "download"
  //   source      = "${var.image_folder}/software-report.json"
  // }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPT_FOLDER=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}", "IMAGE_FOLDER=${var.image_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/configure-system.sh"]
  }

  // provisioner "shell" {
  //   execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  //   inline          = ["sleep 30", "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"]
  // }

}
