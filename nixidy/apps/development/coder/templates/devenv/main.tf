# Coder template `devenv`: one project per workspace. A pod in namespace
# `workspaces` with two volumes, the home (the repository, credentials, caches)
# and a single-user Nix store, which an init container seeds from the image
# (`workspace-seed`). The repository is cloned once; its devenv loads through
# direnv. Pushed by the coder bootstrap Job (nixidy/apps/development/coder),
# which passes the variables below. See docs/dev-workspaces.md.

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.18.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
  }
}

provider "coder" {}

# In-cluster: coderd's ServiceAccount, which has a Role in `namespace` only.
provider "kubernetes" {}

variable "namespace" {
  type    = string
  default = "workspaces"
}

variable "image" {
  type        = string
  description = "harbor.<domain>/library/workspace:<tag>@<digest> (apps/workspace)"
}

variable "storage_class" {
  type    = string
  default = "ceph-block"
}

variable "nodes" {
  type        = string
  description = "Comma-separated nodes the pod may run on, preferred first."
  default     = "falcon,axolotl"
}

variable "bifrost_url" {
  type    = string
  default = "http://bifrost.ai.svc.cluster.local:8000"
}

variable "ai_models" {
  type        = string
  description = "Comma-separated Bifrost models (provider/model) offered to opencode."
  default     = "anthropic/claude-sonnet-4-5,openai/gpt-5,gemini/gemini-2.5-pro"
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "repo" {
  name         = "repo"
  display_name = "Repository"
  description  = "Git URL cloned into the home directory on first start."
  type         = "string"
  default      = "https://github.com/schradert/millionaire.git"
  icon         = "/icon/git.svg"
  mutable      = false
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "Cores requested; the pod may burst above them."
  type         = "number"
  default      = "4"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 cores"
    value = "2"
  }
  option {
    name  = "4 cores"
    value = "4"
  }
  option {
    name  = "8 cores"
    value = "8"
  }
  option {
    name  = "16 cores"
    value = "16"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "GiB, requested and the limit."
  type         = "number"
  default      = "8"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "4 GiB"
    value = "4"
  }
  option {
    name  = "8 GiB"
    value = "8"
  }
  option {
    name  = "16 GiB"
    value = "16"
  }
  option {
    name  = "32 GiB"
    value = "32"
  }
}

data "coder_parameter" "home_size" {
  name         = "home_size"
  display_name = "Home volume"
  description  = "GiB; can grow, not shrink."
  type         = "number"
  default      = "20"
  icon         = "/emojis/1f4be.png"
  mutable      = true
  validation {
    min = 5
    max = 200
  }
}

data "coder_parameter" "nix_size" {
  name         = "nix_size"
  display_name = "Nix store volume"
  description  = "GiB; can grow, not shrink."
  type         = "number"
  default      = "50"
  icon         = "/emojis/2744.png"
  mutable      = true
  validation {
    min = 10
    max = 500
  }
}

locals {
  name    = "coder-${data.coder_workspace.me.id}"
  project = trimsuffix(element(split("/", data.coder_parameter.repo.value), length(split("/", data.coder_parameter.repo.value)) - 1), ".git")
  nodes   = [for n in split(",", var.nodes) : trimspace(n) if trimspace(n) != ""]
  models  = [for m in split(",", var.ai_models) : trimspace(m) if trimspace(m) != ""]
  labels = {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = local.name
    "app.kubernetes.io/part-of"  = "coder"
    "com.coder.resource"         = "true"
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.workspace.name"   = data.coder_workspace.me.name
    "com.coder.user.id"          = data.coder_workspace_owner.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  }
  git_name = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)

  # opencode: Bifrost as an OpenAI-compatible provider (in-cluster, no key).
  opencode_config = jsonencode({
    "$schema"  = "https://opencode.ai/config.json"
    autoupdate = false
    provider = {
      bifrost = {
        npm     = "@ai-sdk/openai-compatible"
        name    = "Bifrost (homelab)"
        options = { baseURL = "${var.bifrost_url}/v1", apiKey = "bifrost" }
        models  = { for m in local.models : m => { name = m } }
      }
    }
  })

  # Every start, on persistent volumes: idempotent, never overwrites the user's files.
  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -u
    toolchain=$(dirname "$(dirname "$(readlink -f "$(command -v bash)")")")
    mkdir -p "$HOME/.config/direnv" "$HOME/.config/opencode"

    if [ ! -e "$HOME/.bashrc" ]; then
      cat > "$HOME/.bashrc" <<'RC'
    eval "$(direnv hook bash)"
    # Claude Code through Bifrost instead of the claude.ai login (no Remote Control then).
    alias claude-bifrost='ANTHROPIC_BASE_URL=$BIFROST_URL/anthropic ANTHROPIC_AUTH_TOKEN=bifrost claude'
    RC
    fi
    [ -e "$HOME/.config/direnv/direnvrc" ] || echo "source $toolchain/share/nix-direnv/direnvrc" > "$HOME/.config/direnv/direnvrc"
    [ -e "$HOME/.config/opencode/opencode.json" ] || cat > "$HOME/.config/opencode/opencode.json" <<'JSON'
    ${local.opencode_config}
    JSON

    project="$HOME/${local.project}"
    if [ ! -d "$project/.git" ]; then
      git clone ${data.coder_parameter.repo.value} "$project" && [ -e "$project/.envrc" ] && direnv allow "$project"
    fi

    # A detached zellij session per project: `zellij attach ${local.project}`.
    (cd "$project" 2>/dev/null || cd "$HOME"; zellij attach --create-background ${local.project} >/dev/null 2>&1 || true)
  EOT
}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = local.startup_script

  env = {
    BIFROST_URL         = var.bifrost_url
    GIT_AUTHOR_NAME     = local.git_name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = local.git_name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  metadata {
    display_name = "CPU"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Memory"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Home"
    key          = "home"
    script       = "coder stat disk --path /home/coder"
    interval     = 60
    timeout      = 1
  }
  metadata {
    display_name = "Nix store"
    key          = "nix"
    script       = "coder stat disk --path /nix"
    interval     = 60
    timeout      = 1
  }

  display_apps {
    vscode                 = false
    vscode_insiders        = false
    web_terminal           = true
    ssh_helper             = true
    port_forwarding_helper = true
  }
}

# Opens the project in Zed over SSH (needs `coder config-ssh` on the client).
resource "coder_app" "zed" {
  agent_id     = coder_agent.main.id
  slug         = "zed"
  display_name = "Zed"
  icon         = "/icon/zed.svg"
  external     = true
  url          = "zed://ssh/coder.${data.coder_workspace.me.name}/home/coder/${local.project}"
  order        = 1
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "${local.name}-home"
    namespace = var.namespace
    labels    = local.labels
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources {
      requests = { storage = "${data.coder_parameter.home_size.value}Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "nix" {
  metadata {
    name      = "${local.name}-nix"
    namespace = var.namespace
    labels    = local.labels
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources {
      requests = { storage = "${data.coder_parameter.nix_size.value}Gi" }
    }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false
  depends_on       = [kubernetes_persistent_volume_claim_v1.home, kubernetes_persistent_volume_claim_v1.nix]

  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "coder-workspace"
        "app.kubernetes.io/instance" = local.name
      }
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false

        security_context {
          run_as_user            = 1000
          run_as_group           = 1000
          run_as_non_root        = true
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = local.nodes
                }
              }
            }
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              preference {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = [local.nodes[0]]
                }
              }
            }
          }
        }
        # The desktops (falcon, axolotl) carry this soft taint.
        toleration {
          key      = "node.trdos.me/class"
          operator = "Exists"
        }

        # Copies the image's Nix store into the store volume (new paths only).
        init_container {
          name    = "seed"
          image   = var.image
          command = ["/bin/workspace-seed"]
          volume_mount {
            name       = "nix"
            mount_path = "/mnt/nix"
          }
          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        container {
          name              = "dev"
          image             = var.image
          image_pull_policy = "IfNotPresent"
          command           = ["sh", "-c", coder_agent.main.init_script]
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          resources {
            requests = {
              cpu    = data.coder_parameter.cpu.value
              memory = "${data.coder_parameter.memory.value}Gi"
            }
            limits = {
              memory = "${data.coder_parameter.memory.value}Gi"
            }
          }
          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
          }
          volume_mount {
            name       = "nix"
            mount_path = "/nix"
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
          }
        }
        volume {
          name = "nix"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nix.metadata[0].name
          }
        }
      }
    }
  }
}

resource "coder_metadata" "workspace" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_deployment_v1.main[0].id
  item {
    key   = "repository"
    value = data.coder_parameter.repo.value
  }
  item {
    key   = "image"
    value = var.image
  }
}
