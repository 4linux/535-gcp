provider "google" {
  region = "us-central1"
}

# Rede principal
resource "google_compute_network" "ansible_network" {
  name                    = "ansible-network"
  auto_create_subnetworks = false
  mtu                     = 1460
  routing_mode            = "REGIONAL"
}

# Sub-rede em us-central1
resource "google_compute_subnetwork" "app_subnet_central" {
  name                     = "ansible-subnet-central"
  ip_cidr_range            = "10.1.0.0/24"
  region                   = "us-central1"
  network                  = google_compute_network.ansible_network.id
  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"
}

# Sub-rede em us-west1
resource "google_compute_subnetwork" "app_subnet_west" {
  name                     = "ansible-subnet-west"
  ip_cidr_range            = "10.2.0.0/24"
  region                   = "us-west1"
  network                  = google_compute_network.ansible_network.id
  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"
}

# Regra de Firewall para liberar HTTP e HTTPS para qualquer endereço (0.0.0.0/0)
resource "google_compute_firewall" "allow_apache" {
  name    = "allow-apache"
  network = google_compute_network.ansible_network.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  direction     = "INGRESS"
  priority      = 1000
  target_tags   = ["allow-apache"]
}


# Regra de Firewall para liberar SSH para qualquer endereço (0.0.0.0/0)
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.ansible_network.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Libera acesso SSH de qualquer lugar
  direction     = "INGRESS"
  priority      = 1000
}

# Regra de Firewall para liberar TCP, UDP e ICMP internamente na rede
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.ansible_network.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.1.0.0/24", "10.2.0.0/24"] # Limita tráfego à rede interna
  direction     = "INGRESS"
  priority      = 1000
}

# Endereço IP Interno Fixo para Ansible Server (Região us-west1)
resource "google_compute_address" "ansible_server_internal_ip" {
  name         = "ansible-server-internal-ip"
  region       = "us-west1"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.app_subnet_west.id
  address      = "10.2.0.11"
}

# Endereços IP Internos Fixos para as outras instâncias (Região us-central1)
resource "google_compute_address" "balancer_server_internal_ip" {
  name         = "balancer-server-internal-ip"
  region       = "us-central1"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.app_subnet_central.id
  address      = "10.1.0.12"
}

resource "google_compute_address" "web_server1_internal_ip" {
  name         = "web-server1-internal-ip"
  region       = "us-central1"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.app_subnet_central.id
  address      = "10.1.0.13"
}

resource "google_compute_address" "web_server2_internal_ip" {
  name         = "web-server2-internal-ip"
  region       = "us-central1"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.app_subnet_central.id
  address      = "10.1.0.14"
}

resource "google_compute_address" "db_server_internal_ip" {
  name         = "db-server-internal-ip"
  region       = "us-central1"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.app_subnet_central.id
  address      = "10.1.0.15"
}

# Endereço IP Externo para Ansible Server (Região us-west1)
resource "google_compute_address" "ansible_server_static_ip" {
  name   = "ansible-server-static-ip"
  region = "us-west1"
}

# Endereço IP Externo para Balancer Server (Região us-central1)
resource "google_compute_address" "balancer_server_static_ip" {
  name   = "balancer-server-static-ip"
  region = "us-central1"
}

# Instância Ansible Server (Região us-west1)
resource "google_compute_instance" "ansible_server" {
  name         = "ansible-server"
  machine_type = "e2-standard-2"
  zone         = "us-west1-a"
  tags         = ["allow-apache"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = "30"
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.ansible_network.id
    subnetwork = google_compute_subnetwork.app_subnet_west.id

    network_ip = google_compute_address.ansible_server_internal_ip.address

    access_config {
      nat_ip = google_compute_address.ansible_server_static_ip.address
    }
  }
  metadata = {
    startup-script = <<-EOF
      #! /bin/bash
      sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
      sed -i '/^#AuthorizedKeysFile/s/^#//' /etc/ssh/sshd_config
      sed -i '/^#PubkeyAuthentication/s/^#//' /etc/ssh/sshd_config
      systemctl restart sshd
      echo "root:4labs-password" | chpasswd
      echo -e "10.2.0.11 ansible-server\n10.1.0.12 balancer-server\n10.1.0.13 web-server1\n10.1.0.14 web-server2\n10.1.0.15 db-server" | sudo tee -a /etc/hosts > /dev/null
    EOF
  }
}

# Instância Balancer Server (Região us-central1)
resource "google_compute_instance" "balancer_server" {
  name         = "balancer-server"
  machine_type = "e2-standard-2"
  zone         = "us-central1-c"
  tags         = ["allow-apache"]

  boot_disk {
    initialize_params {
      image = "centos-cloud/centos-stream-9"
      size  = "30"
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.ansible_network.id
    subnetwork = google_compute_subnetwork.app_subnet_central.id

    network_ip = google_compute_address.balancer_server_internal_ip.address

    access_config {
      nat_ip = google_compute_address.balancer_server_static_ip.address
    }
  }
  metadata = {
    startup-script = <<-EOF
      #! /bin/bash
      sed -i 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
      sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
      systemctl restart sshd
      echo "root:4labs-password" | chpasswd
      echo -e "10.1.0.12 balancer-server\n10.1.0.13 web-server1\n10.1.0.14 web-server2\n10.1.0.15 db-server" | sudo tee -a /etc/hosts > /dev/null      
    EOF
  }
}

# Instância Web Server 1 (Região us-central1)
resource "google_compute_instance" "web_server1" {
  name         = "web-server1"
  machine_type = "e2-small"
  zone         = "us-central1-c"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = "30"
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.ansible_network.id
    subnetwork = google_compute_subnetwork.app_subnet_central.id

    network_ip = google_compute_address.web_server1_internal_ip.address

    access_config {}
  }
  metadata = {
    startup-script = <<-EOF
      #! /bin/bash
      sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
      sed -i '/^#AuthorizedKeysFile/s/^#//' /etc/ssh/sshd_config
      sed -i '/^#PubkeyAuthentication/s/^#//' /etc/ssh/sshd_config
      systemctl restart sshd
      echo "root:4labs-password" | chpasswd
      echo -e "10.2.0.11 ansible-server\n10.1.0.12 balancer-server\n10.1.0.13 web-server1\n10.1.0.14 web-server2\n10.1.0.15 db-server" | sudo tee -a /etc/hosts > /dev/null
    EOF
  }
}

# Instância Web Server 2 (Região us-central1)
resource "google_compute_instance" "web_server2" {
  name         = "web-server2"
  machine_type = "e2-small"
  zone         = "us-central1-c"

  boot_disk {
    initialize_params {
      image = "centos-cloud/centos-stream-9"
      size  = "30"
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.ansible_network.id
    subnetwork = google_compute_subnetwork.app_subnet_central.id

    network_ip = google_compute_address.web_server2_internal_ip.address

    access_config {}
  }
  metadata = {
    startup-script = <<-EOF
      #! /bin/bash
      sed -i 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
      sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
      systemctl restart sshd
      echo "root:4labs-password" | chpasswd
      echo -e "10.2.0.11 ansible-server\n10.1.0.12 balancer-server\n10.1.0.13 web-server1\n10.1.0.14 web-server2\n10.1.0.15 db-server" | sudo tee -a /etc/hosts > /dev/null
    EOF
  }
}

# Instância DB Server (Região us-central1)
resource "google_compute_instance" "db_server" {
  name         = "db-server"
  machine_type = "e2-standard-2"
  zone         = "us-central1-c"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = "30"
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.ansible_network.id
    subnetwork = google_compute_subnetwork.app_subnet_central.id

    network_ip = google_compute_address.db_server_internal_ip.address

    access_config {}
  }
  metadata = {
    startup-script = <<-EOF
      #! /bin/bash
      sed -i 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
      sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
      systemctl restart sshd
      echo "root:4labs-password" | chpasswd
      echo -e "10.2.0.11 ansible-server\n10.1.0.12 balancer-server\n10.1.0.13 web-server1\n10.1.0.14 web-server2\n10.1.0.15 db-server" | sudo tee -a /etc/hosts > /dev/null
    EOF
  }
}

