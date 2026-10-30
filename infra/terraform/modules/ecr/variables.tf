variable "repositories" {
  description = "ECR repository names, one per service"
  type        = list(string)
}

variable "keep_images" {
  description = "Number of images retained per repository"
  type        = number
  default     = 50
}

variable "force_delete" {
  description = "Allow terraform destroy to delete repositories that still contain images (lab use)"
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
