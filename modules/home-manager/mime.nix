# https://github.com/Icy-Thought/snowflake/blob/005878d0c0656fa4d6f39d7ccba4be6c414d96c5/modules/desktop/extensions/mimeApps.nix#L13
{ config
, lib
, ...
}:
let
  inherit (builtins) listToAttrs;
  inherit (lib.attrsets) mapAttrsToList nameValuePair;
  inherit (lib.lists) flatten;
  inherit (lib.modules) mkIf;

  cfg = config.me.mimeApps;
in
{
  options.me.mimeApps =
    let
      inherit (lib.options) mkEnableOption;
      inherit (lib.types) str;
    in
    {
      enable = mkEnableOption "default system applications";
      defApps = {
        editor = lib.mkOption {
          type = str;
          description = "";
          default = "code.desktop";
        };
        fileBrowser = lib.mkOption {
          type = str;
          description = "";
          default = "thunar.desktop";
        };
        imageViewer = lib.mkOption {
          type = str;
          description = "";
          default = "feh.desktop";
        };
        mediaPlayer = lib.mkOption {
          type = str;
          description = "";
          default = "mpv.desktop";
        };
        webBrowser = lib.mkOption {
          type = str;
          description = "";
          default = "firefox.desktop";
        };
        reader = lib.mkOption {
          type = str;
          description = "";
          default = "calibre.desktop";
        };
      };
    };

  config = mkIf cfg.enable {
    xdg.configFile."mimeapps.list".force = true;

    xdg.mimeApps = {
      enable = true;
      defaultApplications =
        let
          defaultApps =
            let
              inherit (cfg.defApps) editor fileBrowser imageViewer mediaPlayer webBrowser reader;
            in
            {
              pdf = [ reader ];
              epub = [ reader ];
              audio = [ mediaPlayer ];
              browser = [ webBrowser ];
              compression = [ fileBrowser ];
              directory = [ fileBrowser ];
              binary = [ fileBrowser ];
              image = [ imageViewer ];
              text = [ editor ];
              video = [ mediaPlayer ];
            };
          mimeMap = {
            pdf = [
              "application/pdf"
            ];
            epub = [
              "application/epub+zip"
            ];
            binary = [
              "application/vnd.android.package-archive" # apk
            ];
            audio = [
              "audio/3gpp"
              "audio/3gpp2"
              "audio/AMR"
              "audio/AMR-WB"
              "audio/aac"
              "audio/ac3"
              "audio/basic"
              "audio/dv"
              "audio/eac3"
              "audio/flac"
              "audio/m4a"
              "audio/midi"
              "audio/mp1"
              "audio/mp2"
              "audio/mp3"
              "audio/mp4"
              "audio/mpeg"
              "audio/mpegurl"
              "audio/mpg"
              "audio/ogg"
              "audio/opus"
              "audio/scpls"
              "audio/vnd.dolby.heaac.1"
              "audio/vnd.dolby.heaac.2"
              "audio/vnd.dolby.mlp"
              "audio/vnd.dts"
              "audio/vnd.dts.hd"
              "audio/vnd.rn-realaudio"
              "audio/vorbis"
              "audio/wav"
              "audio/webm"
              "audio/x-aac"
              "audio/x-adpcm"
              "audio/x-aiff"
              "audio/x-ape"
              "audio/x-flac"
              "audio/x-gsm"
              "audio/x-it"
              "audio/x-m4a"
              "audio/x-matroska"
              "audio/x-mod"
              "audio/x-mp1"
              "audio/x-mp2"
              "audio/x-mp3"
              "audio/x-mpeg"
              "audio/x-mpegurl"
              "audio/x-mpg"
              "audio/x-ms-asf"
              "audio/x-ms-asx"
              "audio/x-ms-wax"
              "audio/x-ms-wma"
              "audio/x-musepack"
              "audio/x-pn-aiff"
              "audio/x-pn-au"
              "audio/x-pn-realaudio"
              "audio/x-pn-realaudio-plugin"
              "audio/x-pn-wav"
              "audio/x-pn-windows-acm"
              "audio/x-real-audio"
              "audio/x-realaudio"
              "audio/x-s3m"
              "audio/x-scpls"
              "audio/x-shorten"
              "audio/x-speex"
              "audio/x-tta"
              "audio/x-vorbis"
              "audio/x-vorbis+ogg"
              "audio/x-wav"
              "audio/x-wavpack"
              "audio/x-xm"
              "x-content/audio-cdda"
              "x-content/audio-player"
            ];
            browser = [
              "text/html"
              "x-scheme-handler/about"
              "x-scheme-handler/http"
              "x-scheme-handler/https"
              "x-scheme-handler/unknown"
            ];
            compression = [
              "application/bzip2"
              "application/gzip"
              "application/vnd.rar"
              "application/x-7z-compressed"
              "application/x-7z-compressed-tar"
              "application/x-bzip"
              "application/x-bzip-compressed-tar"
              "application/x-compress"
              "application/x-compressed-tar"
              "application/x-cpio"
              "application/x-gzip"
              "application/x-lha"
              "application/x-lzip"
              "application/x-lzip-compressed-tar"
              "application/x-lzma"
              "application/x-lzma-compressed-tar"
              "application/x-tar"
              "application/x-tarz"
              "application/x-xar"
              "application/x-xz"
              "application/x-xz-compressed-tar"
              "application/zip"
            ];
            directory = [ "inode/directory" ];
            image = [
              "image/bmp"
              "image/gif"
              "image/jpeg"
              "image/jpg"
              "image/pjpeg"
              "image/png"
              "image/tiff"
              "image/webp"
              "image/x-bmp"
              "image/x-pcx"
              "image/x-png"
              "image/x-portable-anymap"
              "image/x-portable-bitmap"
              "image/x-portable-graymap"
              "image/x-portable-pixmap"
              "image/x-tga"
              "image/x-xbitmap"
              "image/svg+xml"
              "image/vnd.microsoft.icon"
            ];
            text = [
              "text/plain"
              "application/xml"
            ];
            video = [
              "application/smil"
              "application/streamingmedia"
              "application/x-cue"
              "application/x-mpegurl"
              "application/x-ogm"
              "application/x-ogm-video"
              "application/x-shorten"
              "application/x-smil"
              "application/x-streamingmedia"
              "video/mkv"
              "video/x-flic"
              "video/x-mpeg3"
              "video/x-ms-afs"
              "video/x-ms-wvxvideo"
              "application/mpeg4-iod"
              "application/mpeg4-muxcodetable"
              "application/mxf"
              "application/ogg"
              "application/ram"
              "application/sdp"
              "application/vnd.apple.mpegurl"
              "application/vnd.ms-asf"
              "application/vnd.ms-wpl"
              "application/vnd.rn-realmedia"
              "application/vnd.rn-realmedia-vbr"
              "application/x-cd-image"
              "application/x-extension-m4a"
              "application/x-extension-mp4"
              "application/x-flac"
              "application/x-flash-video"
              "application/x-matroska"
              "application/x-ogg"
              "application/x-quicktime-media-link"
              "application/x-quicktimeplayer"
              "application/x-shockwave-flash"
              "application/xspf+xml"
              "image/vnd.rn-realpix"
              "misc/ultravox"
              "text/google-video-pointer"
              "text/x-google-video-pointer"
              "video/3gp"
              "video/3gpp"
              "video/3gpp2"
              "video/avi"
              "video/divx"
              "video/dv"
              "video/fli"
              "video/flv"
              "video/mp2t"
              "video/mp4"
              "video/mp4v-es"
              "video/mpeg"
              "video/mpeg-system"
              "video/msvideo"
              "video/ogg"
              "video/quicktime"
              "video/vnd.divx"
              "video/vnd.mpegurl"
              "video/vnd.rn-realvideo"
              "video/webm"
              "video/x-anim"
              "video/x-avi"
              "video/x-flc"
              "video/x-fli"
              "video/x-flv"
              "video/x-m4v"
              "video/x-matroska"
              "video/x-mpeg"
              "video/x-mpeg-system"
              "video/x-mpeg2"
              "video/x-ms-asf"
              "video/x-ms-asf-plugin"
              "video/x-ms-asx"
              "video/x-ms-wm"
              "video/x-ms-wmv"
              "video/x-ms-wmx"
              "video/x-ms-wvx"
              "video/x-msvideo"
              "video/x-nsv"
              "video/x-ogm"
              "video/x-ogm+ogg"
              "video/x-theora"
              "video/x-theora+ogg"
              "x-content/video-dvd"
              "x-content/video-svcd"
              "x-content/video-vcd"
              "x-scheme-handler/icy"
              "x-scheme-handler/icyx"
              "x-scheme-handler/mms"
              "x-scheme-handler/mmsh"
              "x-scheme-handler/rtmp"
              "x-scheme-handler/rtp"
              "x-scheme-handler/rtsp"

            ];
          };
        in
        listToAttrs (flatten (mapAttrsToList
          (key: types:
            map (type: nameValuePair type (defaultApps."${key}")) types)
          mimeMap));
    };
  };
}
