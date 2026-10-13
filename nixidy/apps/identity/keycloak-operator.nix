{config, ...}: let
  inherit (config.canivete.meta) domain people;
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.keycloak-operator-crds.namespace = "identity";
    canivete.crds.keycloak-operator = {
      application = "keycloak-operator-crds";
      install = true;
      prefix = "config/crd/bases";
      src = pinned.keycloak-operator;
    };
    applications.keycloak-operator = {
      namespace = "identity";
      helm.releases.keycloak-operator = {
        chart = pinned.charts.keycloak-operator;
        values.crds.install = false;
        values.image.tag = with pinned.images.keycloak-operator; "${tag}@${digest}";
      };
      resources.podMonitors.keycloak-operator.spec = {
        selector.matchLabels."app.kubernetes.io/name" = "keycloak-operator";
        podMetricsEndpoints = lib.toList {
          port = "metrics";
          interval = "1m";
        };
      };
    };
    applications.keycloak.resources = {
      keycloakInstances.default.spec = {
        baseUrl = "http://keycloak.identity.svc.cluster.local:8080";
        credentials.secretRef = {
          name = "keycloak";
          usernameKey = "KC_BOOTSTRAP_ADMIN_USERNAME";
          passwordKey = "KC_BOOTSTRAP_ADMIN_PASSWORD";
        };
      };
      keycloakRealms.default.spec = {
        instanceRef.name = "default";
        definition = {
          realm = "default";
          displayName = "Default";
          enabled = true;
          # Fine-grained admin permissions v2 (keycloak-auth.nix groupAdmins).
          adminPermissionsEnabled = true;
          registrationAllowed = false;
          loginWithEmailAllowed = true;
          duplicateEmailsAllowed = false;
          ssoSessionIdleTimeout = 24 * 60 * 60;
          ssoSessionMaxLifespan = 72 * 60 * 60;
          accessTokenLifespan = 5 * 50;
          bruteForceProtected = true;
          # Keycloak rebuilds each policy from the PUT on every reconcile, so every
          # field must be set: a partial policy resets the rest (OTP digits were 0).
          # Passkeys (keycloak-auth.nix flow): user verification required. 26.1 has
          # no "preferred" resident key, so leave it to the authenticator.
          webAuthnPolicyPasswordlessRpEntityName = "Homelab";
          webAuthnPolicyPasswordlessRpId = domain;
          webAuthnPolicyPasswordlessSignatureAlgorithms = ["ES256" "RS256"];
          webAuthnPolicyPasswordlessAttestationConveyancePreference = "not specified";
          webAuthnPolicyPasswordlessAuthenticatorAttachment = "not specified";
          webAuthnPolicyPasswordlessRequireResidentKey = "not specified";
          webAuthnPolicyPasswordlessUserVerificationRequirement = "required";
          webAuthnPolicyPasswordlessCreateTimeout = 0;
          webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister = false;
          webAuthnPolicyPasswordlessAcceptableAaguids = [];
          webAuthnPolicyPasswordlessExtraOrigins = [];
          # Security key as a second factor after the password.
          webAuthnPolicyRpEntityName = "Homelab";
          webAuthnPolicyRpId = domain;
          webAuthnPolicySignatureAlgorithms = ["ES256" "RS256"];
          webAuthnPolicyAttestationConveyancePreference = "not specified";
          webAuthnPolicyAuthenticatorAttachment = "not specified";
          webAuthnPolicyRequireResidentKey = "not specified";
          webAuthnPolicyUserVerificationRequirement = "preferred";
          webAuthnPolicyCreateTimeout = 0;
          webAuthnPolicyAvoidSameAuthenticatorRegister = false;
          webAuthnPolicyAcceptableAaguids = [];
          webAuthnPolicyExtraOrigins = [];
          otpPolicyType = "totp";
          otpPolicyAlgorithm = "HmacSHA1";
          otpPolicyDigits = 6;
          otpPolicyPeriod = 30;
          otpPolicyLookAheadWindow = 1;
          otpPolicyInitialCounter = 0;
          otpPolicyCodeReusable = false;
          smtpServer = {
            host = "stalwart.mail.svc.cluster.local";
            port = "25";
            from = "noreply@${domain}";
            fromDisplayName = "Homelab";
            starttls = "false";
            ssl = "false";
            auth = "false";
          };
        };
      };
      keycloakClientScopes.groups.spec = {
        realmRef.name = "default";
        definition = {
          name = "groups";
          description = "Map user group memberships to the groups claim";
          protocol = "openid-connect";
          attributes."include.in.token.scope" = "true";
          protocolMappers = [
            {
              name = "groups";
              protocol = "openid-connect";
              protocolMapper = "oidc-group-membership-mapper";
              consentRequired = false;
              config = {
                "full.path" = "false";
                "introspection.token.claim" = "true";
                "userinfo.token.claim" = "true";
                "id.token.claim" = "true";
                "access.token.claim" = "true";
                "claim.name" = "groups";
              };
            }
          ];
        };
      };

      # Audiobookshelf only accepts the exact names admin/user/guest in its group
      # claim and asks Keycloak for a scope named like that claim, so it gets its own
      # scope + claim, filled from the groups' `abs_group` attribute.
      keycloakClientScopes.abs-groups.spec = {
        realmRef.name = "default";
        definition = {
          name = "abs_groups";
          description = "Audiobookshelf role names (group attribute abs_group)";
          protocol = "openid-connect";
          attributes."include.in.token.scope" = "true";
          protocolMappers = [
            {
              name = "abs_groups";
              protocol = "openid-connect";
              protocolMapper = "oidc-usermodel-attribute-mapper";
              consentRequired = false;
              config = {
                "user.attribute" = "abs_group";
                "claim.name" = "abs_groups";
                "jsonType.label" = "String";
                # Collect it from the user's groups.
                "aggregate.attrs" = "true";
                "multivalued" = "true";
                "id.token.claim" = "true";
                "access.token.claim" = "true";
                "userinfo.token.claim" = "true";
                "introspection.token.claim" = "true";
              };
            }
          ];
        };
      };

      # Apps map admin rights from the groups claim ("admin"). Apps that only
      # read a role claim get it from group attributes plus a client mapper.
      keycloakGroups.admin.spec = {
        realmRef.name = "default";
        definition = {
          name = "admin";
          attributes.immich_role = ["admin"];
          attributes.abs_group = ["admin"];
        };
      };
      keycloakGroups.family.spec = {
        realmRef.name = "default";
        definition = {
          name = "family";
          attributes.abs_group = ["user"];
        };
      };
      keycloakUsers.tristan.spec = {
        realmRef.name = "default";
        definition = {
          username = people.me;
          # Must equal the email the app bootstraps give their admins, so OIDC
          # logins link to those accounts.
          email = people.my.profiles.personal.email;
          # Set so VERIFY_PROFILE doesn't stop the first login.
          firstName = lib.head (lib.splitString " " people.my.name);
          lastName = lib.last (lib.splitString " " people.my.name);
          emailVerified = true;
          enabled = true;
          groups = ["admin" "family"];
        };
      };
      keycloakRoleMappings.tristan-realm-admin.spec = {
        subject.userRef.name = "tristan";
        role = {
          name = "realm-admin";
          clientId = "realm-management";
        };
      };
    };
  };
}
