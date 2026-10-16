{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "sure.${domain}";
    # false: no ExternalSecret and no token passed to the bootstrap. true once Bitwarden holds
    # `sure/simplefin/token` (docs/manual-steps.md, "Bank sync (SimpleFIN)"): the bootstrap then
    # claims it once into a SimplefinItem for tristan's family.
    simplefin = true;
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/up";
      spec.httpGet.port = "http";
    };
    envFrom = [
      {configMapRef.name = "sure";}
      {secretRef.name = "sure";}
    ];
    # Creates the family + super_admin if missing, then links tristan's Keycloak identity
    # to that user (OidcIdentity: provider `openid_connect` is the name of the env-configured
    # OIDC provider, uid is the token's `sub` = the Keycloak user id, issuer is OIDC_ISSUER),
    # so the first SSO login signs straight in instead of asking for a password to link.
    # The `sub` comes from the Keycloak admin API; Net::HTTP is all it needs.
    bootstrapScript = ''
      require "net/http"
      require "json"
      require "cgi"

      email = ENV.fetch("ADMIN_EMAIL").strip.downcase
      first, last = ENV.fetch("ADMIN_NAME").split(" ", 2)

      kc = ENV.fetch("KEYCLOAK_URL")
      sub = nil
      60.times do
        begin
          res = Net::HTTP.post_form(
            URI("#{kc}/realms/master/protocol/openid-connect/token"),
            grant_type: "password", client_id: "admin-cli",
            username: ENV.fetch("KEYCLOAK_USER"), password: ENV.fetch("KEYCLOAK_PASSWORD")
          )
          raise "keycloak login: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
          token = JSON.parse(res.body).fetch("access_token")
          uri = URI("#{kc}/admin/realms/default/users?username=#{CGI.escape(ENV.fetch("OIDC_USERNAME"))}&exact=true")
          res = Net::HTTP.start(uri.host, uri.port) do |http|
            http.request(Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{token}"))
          end
          raise "keycloak user lookup: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
          sub = JSON.parse(res.body).first&.fetch("id")
          break if sub
          warn "sure-bootstrap: keycloak user not found yet"
        rescue StandardError => e
          warn "sure-bootstrap: #{e.message}"
        end
        sleep 5
      end
      raise "could not resolve the keycloak user" unless sub

      User.transaction do
        user = User.find_by(email: email)
        if user
          puts "sure-bootstrap: user exists"
        else
          user = User.create!(
            email: email, first_name: first, last_name: last,
            password: ENV.fetch("ADMIN_PASSWORD"),
            family: Family.create!, role: :super_admin
          )
          puts "sure-bootstrap: created super_admin"
        end
        identity = OidcIdentity.find_by(provider: "openid_connect", uid: sub)
        if identity
          raise "oidc identity #{sub} is linked to another user" unless identity.user_id == user.id
          puts "sure-bootstrap: oidc identity already linked"
        else
          OidcIdentity.create!(
            user: user, provider: "openid_connect", uid: sub,
            issuer: ENV.fetch("OIDC_ISSUER"), info: { email: email }
          )
          puts "sure-bootstrap: linked oidc identity"
        end
      end

      # Owner's SimpleFIN (flag `simplefin`): Family#create_simplefin_item! is what the Settings UI
      # calls; it claims the setup token (single use) and queues Sure's own sync. Runs only if the
      # family has no SimpleFIN item at all, so it claims once. The item name carries a hash prefix
      # of the token. A new token in Bitwarden does not replace an existing item: use the item's
      # Edit in the UI. Account setup (types) is done below. Failures are logged, never fail the Job.
      if ENV["SIMPLEFIN_SETUP_TOKEN"].to_s.strip != ""
        begin
          token = ENV.fetch("SIMPLEFIN_SETUP_TOKEN").strip
          name = "SimpleFIN (Bitwarden #{Digest::SHA256.hexdigest(token)[0, 8]})"
          family = User.find_by!(email: email).family
          if family.simplefin_items.exists?(name: name)
            puts "sure-simplefin: this token was already claimed"
          elsif family.simplefin_items.exists?
            puts "sure-simplefin: family already has a SimpleFIN item, not claiming (replace it with Edit in the UI)"
          else
            family.create_simplefin_item!(setup_token: token, item_name: name)
            puts "sure-simplefin: claimed the setup token, created #{name}, sync queued"
          end
        rescue StandardError => e
          warn "sure-simplefin: #{e.class} (see docs/manual-steps.md, Bank sync)"
        end
      end

      if ENV["SIMPLEFIN_SETUP_TOKEN"].to_s.strip != ""
        # Account setup for the family's SimpleFIN items (Sure's "setup accounts" step, minus the UI): every
        # account with no Sure account yet gets one, typed by SimpleFIN's own inference plus name/institution
        # heuristics, and the item's pending_account_setup flag is cleared. New Bridge accounts are picked up
        # on the next run. To drop one, disable it in Sure: a deleted or skipped account has no link and is
        # set up again.
        INVESTMENT_ORG = /fidelity|empower|guideline|vanguard|schwab|e\*?trade|robinhood|betterment|wealthfront|principal|t\.? rowe|merrill|john hancock|voya|transamerica|prudential/i
        CARD_ORG = /discover|american express|amex|chase|citi|capital one|barclays|synchrony|bank of america|wells fargo|apple/i

        classify = lambda do |sfa|
          holdings = sfa.raw_holdings_payload.presence || sfa.raw_payload.to_h["holdings"]
          org = sfa.org_data.is_a?(Hash) ? sfa.org_data["name"].to_s : ""
          nm = sfa.name.to_s
          inf = Simplefin::AccountTypeMapper.infer(
            name: nm, holdings: holdings, extra: sfa.extra, balance: sfa.current_balance,
            available_balance: sfa.available_balance, institution: org
          )
          type, subtype = inf.accountable_type, inf.subtype
          if inf.confidence != :high
            bank = nm.match?(/checking|savings|money market|\bcash\b/i)
            type, subtype =
              if org.match?(INVESTMENT_ORG) then ["Investment", nil]
              elsif nm.match?(/loan|mortgage|heloc/i) then ["Loan", nil]
              elsif !bank && (nm.match?(/card|visa|mastercard|amex|discover/i) || org.match?(CARD_ORG) || sfa.current_balance.to_d < 0) then ["CreditCard", "credit_card"]
              else ["Depository", nil]
              end
          end
          # A subtype the account class does not know (the mapper's generic "retirement") is dropped.
          known = { "Depository" => Depository::SUBTYPES, "Investment" => Investment::SUBTYPES, "Loan" => Loan::SUBTYPES }[type]
          subtype = nil if known && !known.key?(subtype)
          subtype = "credit_card" if type == "CreditCard"
          subtype ||= "401k" if type == "Investment" && nm.match?(/401\s*\(?k/i)
          [type, subtype]
        end

        begin
          family = User.find_by!(email: email).family
          family.simplefin_items.active.each do |item|
            # The first (balances-only) discovery sync is queued by the claim; wait for its accounts.
            60.times do
              break if item.simplefin_accounts.reload.exists? || item.syncs.order(:created_at).last&.status.to_s == "failed"
              sleep 5
            end
            todo = item.simplefin_accounts.left_joins(:account, :account_provider)
                       .where(accounts: { id: nil }, account_providers: { id: nil }).to_a
            todo.each do |sfa|
              type, subtype = classify.call(sfa)
              account = Account.create_from_simplefin_account(sfa, type, subtype)
              sfa.update!(account: account)
              sfa.ensure_account_provider!
              puts "sure-simplefin: set up #{sfa.name} as #{type}#{subtype ? " (#{subtype})" : ""}"
            end
            if todo.any?
              item.update!(pending_account_setup: false)
              item.sync_later
              puts "sure-simplefin: #{todo.size} account(s) set up on #{item.name}, full sync queued"
            elsif item.simplefin_accounts.exists?
              puts "sure-simplefin: all accounts of #{item.name} already set up"
            end
          end
        rescue StandardError => e
          warn "sure-simplefin: account setup failed: #{e.class} #{e.message}"
        end
      end
    '';

    bootstrapSpec = {
      backoffLimit = 6;
      activeDeadlineSeconds = 1200;
      template.spec = {
        restartPolicy = "OnFailure";
        automountServiceAccountToken = false;
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 1000;
          runAsGroup = 1000;
          seccompProfile.type = "RuntimeDefault";
        };
        containers = lib.toList {
          name = "bootstrap";
          image = with pinned.images.sure; "${repository}:${tag}@${digest}";
          args = ["./bin/rails" "runner" bootstrapScript];
          inherit envFrom;
          env =
            lib.optional simplefin {
              name = "SIMPLEFIN_SETUP_TOKEN";
              valueFrom.secretKeyRef = {
                name = "sure-simplefin";
                key = "token";
              };
            }
            ++ [
              {
                name = "ADMIN_EMAIL";
                value = people.my.profiles.personal.email;
              }
              {
                name = "ADMIN_NAME";
                value = people.my.name;
              }
              {
                name = "KEYCLOAK_URL";
                value = "http://keycloak.identity.svc.cluster.local:8080";
              }
              {
                name = "KEYCLOAK_USER";
                value = "admin";
              }
              {
                name = "KEYCLOAK_PASSWORD";
                valueFrom.secretKeyRef = {
                  name = "sure-keycloak-admin";
                  key = "password";
                };
              }
              {
                name = "OIDC_USERNAME";
                value = people.me;
              }
              {
                name = "ADMIN_PASSWORD";
                valueFrom.secretKeyRef = {
                  name = "sure-admin";
                  key = "password";
                };
              }
            ];
          securityContext = {
            allowPrivilegeEscalation = false;
            capabilities.drop = ["ALL"];
          };
        };
      };
    };
  in {
    applications.keycloak.resources.keycloakClients.sure.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "sure";
        create = true;
      };
      definition = {
        clientId = "sure";
        name = "Sure Finance";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/auth/openid_connect/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    portal.apps.sure = {
      title = "Sure";
      icon = "mdi-finance";
      description = "Financial planning";
    };
    gatus.endpoints.sure = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.sure = {
      namespace = "finance";
      postgres.enable = true;
      # sirver (failing root disk) hosts the lone instance today; keep a standby elsewhere.
      postgres.instances = 2;
      postgres.database = "sure_production";
      volsync.pvcs.sure.title = "sure";
      generatedSecrets.sure-admin = {
        key = "password";
        upper = true;
        bitwarden = "sure/admin-password";
      };

      helm.releases.sure = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.sure = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.sure = {
              image = pinned.images.sure;
              resources.requests = {
                cpu = "25m";
                memory = "352Mi";
              };
              inherit envFrom;
              ports = lib.toList {
                name = "http";
                containerPort = 3000;
              };
              probes.liveness = probe {};
              probes.readiness = probe {
                spec.initialDelaySeconds = 15;
                spec.timeoutSeconds = 1;
              };
              probes.startup = probe {
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };

          controllers.sure-worker = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.sure-worker = {
              image = pinned.images.sure;
              resources.requests = {
                cpu = "40m";
                memory = "320Mi";
              };
              args = ["bundle" "exec" "sidekiq"];
              inherit envFrom;
              probes.liveness.enabled = false;
              probes.readiness.enabled = false;
              probes.startup.enabled = false;
            };
          };

          service.sure = {
            controller = "sure";
            ports.http.port = 3000;
          };

          configMaps.sure.data = {
            SELF_HOSTED = "true";
            RAILS_ENV = "production";
            RAILS_ASSUME_SSL = "true";
            DB_HOST = "sure-rw";
            DB_PORT = "5432";
            POSTGRES_USER = "sure";
            REDIS_URL = "redis://sure-dragonfly.finance.svc.cluster.local:6379/0";
            # Self-registration closed and no JIT account creation: the only account is
            # the bootstrapped one, which the Keycloak login links to once.
            ONBOARDING_STATE = "closed";
            AUTH_JIT_MODE = "link_only";
            APP_DOMAIN = hostname;
            OIDC_ISSUER = "https://keycloak.${domain}/realms/default";
            OIDC_REDIRECT_URI = "https://${hostname}/auth/openid_connect/callback";
          };

          persistence.storage = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "5Gi";
            advancedMounts.sure.sure = [{path = "/rails/storage";}];
          };
        };
      };
      resources.httpRoutes.sure.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "sure";
            port = 3000;
          };
        };
      };

      # Idempotent first-user bootstrap (README "Conventions"): creates the family
      # and the super_admin only when no account with this email exists, and links
      # tristan's Keycloak identity to it (see bootstrapScript), so SSO works from
      # the first login without the link_only password confirmation. sure/admin-password
      # in Bitwarden stays as the break-glass password.
      resources.jobs.sure-bootstrap = {
        metadata.annotations = {
          "argocd.argoproj.io/hook" = "PostSync";
          "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
        };
        spec = bootstrapSpec;
      };

      # The same bootstrap daily: a SimpleFIN account added in the Bridge later (a new card) is set up
      # in Sure without waiting for the next deploy. At an odd minute, after Sure's own daily sync.
      resources.cronJobs.sure-bootstrap = lib.mkIf simplefin {
        spec = {
          schedule = "17 10 * * *";
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = bootstrapSpec // {ttlSecondsAfterFinished = 172800;};
        };
      };

      # DragonflyDB instance for Redis (Sidekiq queue + caching)
      resources.dragonflies.sure-dragonfly.spec = {
        replicas = 1;
        args = ["--proactor_threads" "2"];
        resources.requests.cpu = "30m";
        resources.requests.memory = "256Mi";
        resources.limits.memory = "1Gi";
      };

      # Keycloak master-realm admin, to resolve tristan's `sub` (same Bitwarden entry
      # as the keycloak app itself).
      resources.externalSecrets.sure-keycloak-admin.spec.data = lib.toList {
        secretKey = "password";
        remoteRef.key = "keycloak/admin/password";
        sourceRef.storeRef.name = "bitwarden";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };

      resources.externalSecrets.sure-simplefin = lib.mkIf simplefin {
        spec.data = lib.toList {
          secretKey = "token";
          remoteRef.key = "sure/simplefin/token";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };

      resources.externalSecrets.sure.spec.data = [
        {
          secretKey = "SECRET_KEY_BASE";
          remoteRef.key = "sure/secret_key_base";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "POSTGRES_PASSWORD";
          remoteRef.key = "sure-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-finance";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "OIDC_CLIENT_ID";
          remoteRef.key = "sure";
          remoteRef.property = "client-id";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "OIDC_CLIENT_SECRET";
          remoteRef.key = "sure";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
  };
}
