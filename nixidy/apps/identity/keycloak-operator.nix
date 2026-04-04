{config, ...}: let
  inherit (config.canivete.meta) domain people;
in {
  nixidy = {
    lib,
    pkgs,
    ...
  }: {
    applications.keycloak-operator-crds.namespace = "identity";
    canivete.crds.keycloak-operator = {
      application = "keycloak-operator-crds";
      install = true;
      prefix = "config/crd/bases";
      src = pkgs.fetchFromGitHub {
        owner = "Hostzero-GmbH";
        repo = "keycloak-operator";
        rev = "v0.5.0";
        hash = "sha256-clKEPJdzV/4xulB4dEMOJdeNd8wHl6ev23FDhmIzRY0=";
      };
    };
    applications.keycloak-operator = {
      namespace = "identity";
      helm.releases.keycloak-operator = {
        chart = lib.helm.downloadHelmChart {
          chart = "keycloak-operator";
          version = "0.5.0";
          repo = "oci://ghcr.io/hostzero-gmbh/charts";
          chartHash = "sha256-hB9AgNnS0Ia1PGEnEbxaCbVrNUmKoPn4bNo0dfoAYsQ=";
        };
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
          webAuthnPolicyRpEntityName = "Homelab Default Realm";
          webAuthnPolicyRpId = domain;
          otpPolicyType = "totp";
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

      keycloakGroups.admin.spec = {
        realmRef.name = "default";
        definition.name = "admin";
      };
      keycloakGroups.family.spec = {
        realmRef.name = "default";
        definition.name = "family";
      };
      keycloakUsers.tristan.spec = {
        realmRef.name = "default";
        definition = {
          username = people.me;
          email = people.my.profiles.personal.email;
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
