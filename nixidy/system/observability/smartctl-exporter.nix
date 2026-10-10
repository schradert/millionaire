{
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.smartctl-exporter = {
      namespace = "observability";
      helm.releases.smartctl-exporter = {
        chart = pinned.charts.prometheus-smartctl-exporter;
        values = {
          fullnameOverride = "smartctl-exporter";
          # The chart's own rules are generic; ours are below.
          prometheusRules.enabled = false;
          # Stay on v0.14.0: v0.15.0 and master answer HTTP 500 on any host with SCSI
          # disks (the new verify-error metrics are missing from Describe, so the
          # whole scrape fails). v0.14.0 just doesn't export the verify counters.
          image = {
            inherit (pinned.images.smartctl-exporter) repository;
            tag = with pinned.images.smartctl-exporter; "${tag}@${digest}";
          };
          # sirver's PERC is in passthrough, so every disk is scanned twice: as /dev/sdX
          # and as /dev/bus/0;megaraid,N. That duplicates every series and alert, so
          # sirver gets its own instance that skips the megaraid route. Everywhere else
          # (octopus) the megaraid route is the only one that reaches the real disks.
          affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = lib.toList {
            matchExpressions = lib.toList {
              key = "kubernetes.io/hostname";
              operator = "NotIn";
              values = ["sirver"];
            };
          };
          extraInstances = lib.toList {
            config.device_exclude = "/dev/bus/.*";
            nodeSelector."kubernetes.io/hostname" = "sirver";
            tolerations = lib.toList {operator = "Exists";};
          };
          # Privileged with /dev mounted: one pod per node, tolerating every taint.
          serviceMonitor = {
            enabled = true;
            # Prometheus only selects monitors labelled release=prometheus.
            extraLabels.release = "prometheus";
            attachMetadata.node = true;
            relabelings = lib.toList {
              sourceLabels = ["__meta_kubernetes_pod_node_name"];
              targetLabel = "node";
            };
          };
        };
      };
      # nixidy strips the chart's version and chart labels from the Service but
      # the ServiceMonitor selector still requires them, so it matched nothing.
      resources.serviceMonitors.smartctl-exporter.spec.selector.matchLabels = lib.mkForce {
        "app.kubernetes.io/instance" = "smartctl-exporter";
        "app.kubernetes.io/name" = "prometheus-smartctl-exporter";
      };
      # Selected by the Prometheus CR's ruleSelector (release: prometheus). Joined to
      # smartctl_device so alerts carry the disk's model and serial.
      resources.prometheusRules.smart = let
        disk = "on (node, device) group_left (model_name, serial_number) smartctl_device";
        where = ''{{ $labels.node }} {{ $labels.device }} ({{ $labels.model_name }} {{ $labels.serial_number }})'';
      in {
        metadata.labels.release = "prometheus";
        spec.groups = lib.toList {
          name = "smart";
          rules = [
            {
              alert = "DiskSmartFailing";
              expr = "(smartctl_device_smart_status == 0) * ${disk}";
              "for" = "10m";
              labels.severity = "critical";
              annotations.summary = "SMART health check failed on ${where}";
              annotations.description = "The drive reports failure imminent (SMART status not OK; SCSI ASC 0x5D on SAS disks). Replace it.";
            }
            {
              alert = "DiskGrownDefectsGrowing";
              expr = ''
                (
                  delta(smartctl_scsi_grown_defect_list[1d]) > 0
                  or delta(smartctl_device_attribute{attribute_name=~"Reallocated_Sector_Ct|Reallocated_Event_Count|Current_Pending_Sector|Offline_Uncorrectable",attribute_value_type="raw"}[1d]) > 0
                ) * ${disk}
              '';
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "Bad sectors grew in the last day on ${where}";
              annotations.description = "Grown defects (SAS) or reallocated/pending sectors (ATA) increased: the media is wearing out.";
            }
            {
              alert = "DiskUncorrectedErrors";
              expr = ''
                (
                  smartctl_read_total_uncorrected_errors > 0
                  or smartctl_write_total_uncorrected_errors > 0
                  or smartctl_device_media_errors > 0
                ) * ${disk}
              '';
              "for" = "10m";
              labels.severity = "warning";
              annotations.summary = "Uncorrected I/O errors on ${where}";
              annotations.description = "The drive's lifetime read/write (SAS) or media (NVMe) uncorrected error counter is nonzero. The exporter does not export SAS verify errors.";
            }
            {
              alert = "DiskUncorrectedErrorsGrowing";
              expr = ''
                (
                  delta(smartctl_read_total_uncorrected_errors[6h]) > 0
                  or delta(smartctl_write_total_uncorrected_errors[6h]) > 0
                  or delta(smartctl_device_media_errors[6h]) > 0
                ) * ${disk}
              '';
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "Uncorrected I/O errors are increasing on ${where}";
              annotations.description = "Uncorrected errors grew within 6h: data on this drive is being lost or unreadable now.";
            }
            {
              alert = "DiskCriticalWarning";
              expr = "(smartctl_device_critical_warning != 0) * ${disk}";
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "NVMe critical warning on ${where}";
            }
            {
              alert = "DiskTemperatureHigh";
              expr = ''(smartctl_device_temperature{temperature_type="current"} > 55) * ${disk}'';
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "${where} is above 55C";
            }
            {
              alert = "DiskTemperatureCritical";
              expr = ''(smartctl_device_temperature{temperature_type="current"} > 65) * ${disk}'';
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "${where} is above 65C";
            }
            {
              alert = "SmartctlExporterDown";
              expr = ''up{job="smartctl-exporter"} == 0'';
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "No disk SMART metrics from {{ $labels.node }}";
            }
          ];
        };
      };
    };
  };
}
