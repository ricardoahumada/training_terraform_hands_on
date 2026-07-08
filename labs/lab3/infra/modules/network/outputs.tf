output "vpc_self_link" {
  value = google_compute_network.applocker.self_link
}

output "vpc_id" {
  value = google_compute_network.applocker.id
}

output "subnet_self_links" {
  value = {
    app        = google_compute_subnetwork.app.self_link
    middleware = google_compute_subnetwork.middleware.self_link
    lock       = google_compute_subnetwork.lock.self_link
    data       = google_compute_subnetwork.data.self_link
  }
}

output "router_name" {
  value = google_compute_router.applocker.name
}

output "nat_name" {
  value = google_compute_router_nat.applocker.name
}

output "private_ip_range_name" {
  # value = google_compute_global_address.private_ip_range.name
  value = module.peering.private_ip_range_name
}