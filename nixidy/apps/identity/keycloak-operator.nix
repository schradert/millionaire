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

      # Apps map admin rights from the groups claim ("admin"). Apps that only
      # read a role claim get it from group attributes plus a client mapper.
      keycloakGroups.admin.spec = {
        realmRef.name = "default";
        definition = {
          name = "admin";
          attributes.immich_role = ["admin"];
        };
      };
      keycloakGroups.family.spec = {
        realmRef.name = "default";
        definition.name = "family";
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
