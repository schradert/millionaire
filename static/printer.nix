{
  flake,
  lib,
  pkgs,
  ...
}: {
  imports = with flake.inputs.srvos.nixosModules; [server mixins-terminfo];

  networking.firewall.allowedTCPPorts = [7125];

  services.klipper = {
    enable = true;
    # Voron 2.4 LDO reference config — adjust after first boot
    settings = {
      mcu.serial = "/dev/serial/by-id/usb-Klipper_stm32f446xx_placeholder-if00";

      printer = {
        kinematics = "corexy";
        max_velocity = 300;
        max_accel = 3000;
        max_z_velocity = 15;
        max_z_accel = 350;
        square_corner_velocity = 5.0;
      };

      # Voron 2.4 300mm bed — adjust for your build size
      stepper_x = {
        step_pin = "PF13";
        dir_pin = "PF12";
        enable_pin = "!PF14";
        rotation_distance = 40;
        microsteps = 32;
        full_steps_per_rotation = 200;
        endstop_pin = "PG6";
        position_min = 0;
        position_endstop = 300;
        position_max = 300;
        homing_speed = 25;
        homing_retract_dist = 5;
        homing_positive_dir = true;
      };

      stepper_y = {
        step_pin = "PG0";
        dir_pin = "PG1";
        enable_pin = "!PF15";
        rotation_distance = 40;
        microsteps = 32;
        full_steps_per_rotation = 200;
        endstop_pin = "PG9";
        position_min = 0;
        position_endstop = 300;
        position_max = 300;
        homing_speed = 25;
        homing_retract_dist = 5;
        homing_positive_dir = true;
      };

      # Z steppers (Voron 2.4 quad gantry level — 4 Z motors)
      stepper_z = {
        step_pin = "PF11";
        dir_pin = "PG3";
        enable_pin = "!PG5";
        rotation_distance = 40;
        gear_ratio = "80:16";
        microsteps = 32;
        endstop_pin = "PG10";
        position_max = 260;
        position_min = -5;
        homing_speed = 8;
        second_homing_speed = 3;
        homing_retract_dist = 3;
      };
      stepper_z1 = {
        step_pin = "PG4";
        dir_pin = "!PC1";
        enable_pin = "!PA2";
        rotation_distance = 40;
        gear_ratio = "80:16";
        microsteps = 32;
      };
      stepper_z2 = {
        step_pin = "PF9";
        dir_pin = "PF10";
        enable_pin = "!PG2";
        rotation_distance = 40;
        gear_ratio = "80:16";
        microsteps = 32;
      };
      stepper_z3 = {
        step_pin = "PC13";
        dir_pin = "!PF0";
        enable_pin = "!PF1";
        rotation_distance = 40;
        gear_ratio = "80:16";
        microsteps = 32;
      };

      extruder = {
        step_pin = "PE2";
        dir_pin = "PE3";
        enable_pin = "!PD4";
        rotation_distance = 22.6789511;
        gear_ratio = "50:10";
        microsteps = 32;
        full_steps_per_rotation = 200;
        nozzle_diameter = 0.400;
        filament_diameter = 1.750;
        heater_pin = "PA1";
        sensor_type = "ATC Semitec 104NT-4-R025H42G";
        sensor_pin = "PF4";
        min_temp = 10;
        max_temp = 270;
        max_power = 1.0;
        min_extrude_temp = 170;
        pressure_advance = 0.05;
        pressure_advance_smooth_time = 0.040;
      };

      heater_bed = {
        heater_pin = "PA0";
        sensor_type = "ATC Semitec 104NT-4-R025H42G";
        sensor_pin = "PF3";
        max_power = 0.6;
        min_temp = 0;
        max_temp = 120;
      };

      "temperature_sensor chamber" = {
        sensor_type = "ATC Semitec 104NT-4-R025H42G";
        sensor_pin = "PF5";
        min_temp = 0;
        max_temp = 100;
        gcode_id = "chamber";
      };

      fan = {
        pin = "PE5";
        kick_start_time = 0.5;
        off_below = 0.10;
      };

      "heater_fan hotend_fan" = {
        pin = "PA8";
        max_power = 1.0;
        kick_start_time = 0.5;
        heater = "extruder";
        heater_temp = 50.0;
      };

      "controller_fan controller_fan" = {
        pin = "PD12";
        kick_start_time = 0.5;
        heater = "heater_bed";
      };

      quad_gantry_level = {
        gantry_corners = "
          -60,-10
          360,370";
        points = "
          50,25
          50,225
          250,225
          250,25";
        speed = 100;
        horizontal_move_z = 10;
        retries = 5;
        retry_tolerance = 0.0075;
        max_adjust = 10;
      };

      bed_mesh = {
        speed = 120;
        horizontal_move_z = 5;
        mesh_min = "35,26";
        mesh_max = "265,273";
        probe_count = "5,5";
        algorithm = "bicubic";
      };

      probe = {
        pin = "PG15";
        x_offset = 0;
        y_offset = 25.0;
        speed = 10.0;
        samples = 3;
        samples_result = "median";
        sample_retract_dist = 3.0;
        samples_tolerance = 0.006;
        samples_tolerance_retries = 3;
      };

      idle_timeout.timeout = 1800;

      "neopixel headlight" = {
        pin = "PB0";
        chain_count = 3;
        color_order = "GRBW";
        initial_RED = 0.0;
        initial_GREEN = 0.0;
        initial_BLUE = 0.0;
        initial_WHITE = 0.0;
      };

      board_pins.aliases = lib.concatStringsSep ", " [
        "EXP1_1=PE8"
        "EXP1_2=PE7"
        "EXP1_3=PE9"
        "EXP1_4=PE10"
        "EXP1_5=PE12"
        "EXP1_6=PE13"
        "EXP1_7=PE14"
        "EXP1_8=PE15"
        "EXP1_9=<GND>"
        "EXP1_10=<5V>"
        "EXP2_1=PA6"
        "EXP2_2=PA5"
        "EXP2_3=PB1"
        "EXP2_4=PA4"
        "EXP2_5=PB2"
        "EXP2_6=PA7"
        "EXP2_7=PC15"
        "EXP2_8=<RST>"
        "EXP2_9=<GND>"
        "EXP2_10=<5V>"
      ];
    };
    # Klipper plugins
    firmwares.mcu = {
      enable = true;
      configFile = ./klipper-mcu.config;
      # serial set to null — flash manually after first boot
      serial = null;
    };
  };

  services.moonraker = {
    enable = true;
    address = "0.0.0.0";
    allowSystemControl = true;
    settings = {
      authorization = {
        trusted_clients = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "127.0.0.0/8"
          "::1/128"
          "FE80::/10"
        ];
        cors_domains = [
          "*.trdos.me"
          "http://localhost"
          "http://localhost:*"
        ];
      };
      octoprint_compat = {};
      history = {};
      "spoolman" = {
        server = "https://spoolman.trdos.me";
        sync_rate = 5;
      };
      "webcam cam" = {
        location = "printer";
        icon = "mdiPrinter3d";
        enabled = true;
        service = "mjpegstreamer";
        target_fps = 15;
        target_fps_idle = 5;
        stream_url = "/webcam/?action=stream";
        snapshot_url = "/webcam/?action=snapshot";
        aspect_ratio = "16:9";
      };
      timelapse = {
        output_path = "~/timelapse/";
        frame_path = "/tmp/timelapse/";
        ffmpeg_binary_path = "${pkgs.ffmpeg}/bin/ffmpeg";
      };
    };
  };

  # Crowsnest-style webcam streaming via ustreamer
  systemd.services.ustreamer = {
    description = "ustreamer webcam streamer";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStart = "${pkgs.ustreamer}/bin/ustreamer --host 0.0.0.0 --port 8080 --device /dev/video0 --resolution 1280x720 --format MJPEG --desired-fps 15";
      Restart = "always";
      User = "moonraker";
    };
  };

  # KlipperScreen: package exists in nixpkgs (pkgs.klipperscreen) but no
  # NixOS service module — wire up via systemd.services after first boot.

  # Moonraker-obico for AI failure detection (connects to self-hosted Obico on k8s)
  # TODO: configure after Obico server is deployed
  # systemd.services.moonraker-obico = { ... };

  services.fluidd.enable = false;
  services.mainsail.enable = false;
}
