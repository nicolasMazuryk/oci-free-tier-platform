plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# The Makefile exports one TF_VAR set (tenancy_ocid, user_ocid) for every layer,
# so some layers declare variables they do not use on purpose.
rule "terraform_unused_declarations" {
  enabled = false
}
