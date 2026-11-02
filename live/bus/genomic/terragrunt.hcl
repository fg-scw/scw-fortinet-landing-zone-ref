include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "bu" {
  path = find_in_parent_folders("bu.hcl")
}
