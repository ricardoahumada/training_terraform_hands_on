locals {
  common_labels = {
    app         = "applocker"
    env         = var.env
    team        = "platform-mm"
    managed-by  = "terraform"
    cost-center = "cc-1042"
  }
}