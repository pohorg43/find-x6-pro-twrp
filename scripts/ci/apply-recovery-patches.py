#!/usr/bin/env python3
from pathlib import Path
from textwrap import dedent
import subprocess, tempfile

def patch_file(path_str, replacements):
    p = Path(path_str)
    orig = p.read_text()
    backup = Path(tempfile.gettempdir()) / (p.name + ".orig")
    backup.write_text(orig)
    src = orig
    for label, target, repl in replacements:
        cnt = src.count(target)
        assert cnt == 1, f"{path_str} [{label}]: expected 1 match, found {cnt}"
        src = src.replace(target, repl, 1)
    p.write_text(src)
    subprocess.run(["diff", "-u", str(backup), path_str], check=False)
    backup.unlink(missing_ok=True)

def write_new_file(path_str, content):
    p = Path(path_str)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(dedent(content).lstrip("\n"))
    print(f"=== Wrote {path_str} ({p.stat().st_size} bytes) ===")

# 1. Propagate TW_NO_FLASH_CURRENT_TWRP through BoardConfigSoong.mk & bootable/recovery/twrp_flags.go
patch_file("vendor/twrp/config/BoardConfigSoong.mk", [
    (
        "export TW_NO_FLASH_CURRENT_TWRP",
        "    AB_OTA_UPDATER \\\n",
        "    AB_OTA_UPDATER \\\n    TW_NO_FLASH_CURRENT_TWRP \\\n",
    ),
])
patch_file("bootable/recovery/twrp_flags.go", [
    (
        "TW_NO_FLASH_CURRENT_TWRP",
        "\tif makeBoolValue(getVar(\"AB_OTA_UPDATER\")) {\n\t\tflags = append(flags, \"-DAB_OTA_UPDATER=1\")\n\t}\n",
        "\tif makeBoolValue(getVar(\"AB_OTA_UPDATER\")) {\n\t\tflags = append(flags, \"-DAB_OTA_UPDATER=1\")\n\t}\n\tif makeBoolValue(getVar(\"TW_NO_FLASH_CURRENT_TWRP\")) {\n\t\tflags = append(flags, \"-DTW_NO_FLASH_CURRENT_TWRP\")\n\t}\n",
    ),
])

# 2. Hide unsafe tools for PGEM10 and add Step E flashlight/module manager backend
patch_file("bootable/recovery/twrp_functions.hpp", [
    (
        "declare DisableFlashlight",
        "  // Removes the bootloader message from misc for next boot\n  static void ClearBootloaderMessage();\n",
        "  // Removes the bootloader message from misc for next boot\n  static void ClearBootloaderMessage();\n\n  // Turns off camera/torch LEDs safely when shutting down or rebooting\n  static void DisableFlashlight();\n",
    ),
])

patch_file("bootable/recovery/twrp_functions.cpp", [
    (
        "implement DisableFlashlight and call in TwReboot",
        "// reboot: Reboot the system. Return -1 on error, no return on success\nint TWFunc::TwReboot(const RebootCommand command) {\n  DataManager::Flush();\n  UpdateLogFile();\n",
        dedent("""\
        void TWFunc::DisableFlashlight() {
          static constexpr const char* kFlashResetPaths[] = {
              "/sys/class/leds/led:switch_2/brightness",
              "/sys/class/leds/led:switch_0/brightness",
              "/sys/class/leds/led:switch_1/brightness",
              "/sys/class/leds/led:torch_0/brightness",
              "/sys/class/leds/led:torch_1/brightness",
              "/sys/class/leds/led:torch_2/brightness",
              "/sys/class/leds/led:torch_3/brightness",
          };
          for (const char* path : kFlashResetPaths) {
            if (access(path, W_OK) != 0) continue;
            const int fd = open(path, O_WRONLY | O_CLOEXEC);
            if (fd < 0) continue;
            const ssize_t written = write(fd, "0\\n", 2);
            (void)written;
            close(fd);
          }
        }

        // reboot: Reboot the system. Return -1 on error, no return on success
        int TWFunc::TwReboot(const RebootCommand command) {
          DisableFlashlight();
          DataManager::Flush();
          UpdateLogFile();
        """),
    ),
])

patch_file("bootable/recovery/twrp.cpp", [
    (
        "include mount and kernel_module_loader",
        "#include \"startup/startup_args.hpp\"\n",
        "#include <sys/mount.h>\n#include \"kernel_module_loader.hpp\"\n#include \"startup/startup_args.hpp\"\n",
    ),
    (
        "fastbootd load vendor modules and guarantee unmount before UnmapSuperDevices",
        "\tfor (auto& preparePart : prepareParts) {\n\t\tTWPartition *part = PartitionManager.FindPartitionByPath(preparePart);\n\t\tif (part) PartitionManager.PrepareSuperVolume(part);\n\t}\n#endif\n",
        dedent("""\
        \tfor (auto& preparePart : prepareParts) {
        \t\tTWPartition *part = PartitionManager.FindPartitionByPath(preparePart);
        \t\tif (part) PartitionManager.PrepareSuperVolume(part);
        \t}
        \tKernelModuleLoader::LoadVendorModules();
        \tfor (auto it = prepareParts.rbegin(); it != prepareParts.rend(); ++it) {
        \t\tTWPartition *part = PartitionManager.FindPartitionByPath(*it);
        \t\tif (part && part->IsMounted()) {
        \t\t\tif (!part->Unmount(false)) {
        \t\t\t\tTWFunc::KillForUseTargetProcess(part->GetMountPoint());
        \t\t\t\tif (!part->Unmount(false, MNT_DETACH)) {
        \t\t\t\t\tLOGERR("fastbootd: failed to unmount %s before UnmapSuperDevices\\n", it->c_str());
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        #endif
        """),
    ),
    (
        "disable flashlight when gui2 exits",
        "\tconst int gui2_result = gui2_start(&gui2_context_value);\n\tbacklight.stop();\n",
        "\tconst int gui2_result = gui2_start(&gui2_context_value);\n\tbacklight.stop();\n\tTWFunc::DisableFlashlight();\n",
    ),
])

patch_file("bootable/recovery/gui2/backend/tools_backend.h", [
    (
        "add module_entry and flashlight/modules availability",
        "  // The sideload button needs data media.\n  bool sideload = false;\n};\n",
        dedent("""\
          // The sideload button needs data media.
          bool sideload = false;
          bool flashlight = false;
          bool modules = false;
        };

        struct module_entry {
          std::string id;
          std::string name;
          std::string version;
          bool enabled = true;
        };
        """),
    ),
    (
        "add flashlight and modules methods to tools_backend",
        "  virtual tool_state status() = 0;\n  virtual void acknowledge() = 0;\n};\n",
        dedent("""\
          virtual tool_state status() = 0;
          virtual void acknowledge() = 0;

          // Flashlight sysfs control.
          virtual bool flashlight_enabled() = 0;
          virtual int flashlight_step() = 0;
          virtual bool set_flashlight(bool enabled, int step) = 0;
          virtual void disable_flashlight() = 0;

          // Magisk / KernelSU / APatch module manager (/data/adb/modules).
          virtual bool data_ready_for_modules() = 0;
          virtual std::vector<module_entry> list_modules() = 0;
          virtual bool set_module_enabled(const std::string& id, bool enabled) = 0;
          virtual int disable_all_modules() = 0;
          virtual bool delete_module(const std::string& id) = 0;
        };
        """),
    ),
])

patch_file("bootable/recovery/gui2/backend/twrp_tools_backend.h", [
    (
        "include vector in twrp_tools_backend.h",
        "#include <atomic>\n#include <mutex>\n#include <thread>\n",
        "#include <atomic>\n#include <mutex>\n#include <string>\n#include <thread>\n#include <vector>\n",
    ),
    (
        "declare flashlight/modules methods in twrp_tools_backend",
        "  tool_state status() override;\n  void acknowledge() override;\n\n private:\n",
        dedent("""\
          tool_state status() override;
          void acknowledge() override;

          bool flashlight_enabled() override;
          int flashlight_step() override;
          bool set_flashlight(bool enabled, int step) override;
          void disable_flashlight() override;

          bool data_ready_for_modules() override;
          std::vector<module_entry> list_modules() override;
          bool set_module_enabled(const std::string& id, bool enabled) override;
          int disable_all_modules() override;
          bool delete_module(const std::string& id) override;

         private:
          int flashlight_step_ = 10;
        """),
    ),
])

patch_file("bootable/recovery/gui2/backend/twrp_tools_backend.cpp", [
    (
        "include posix headers for sysfs and module manager",
        "#include <unistd.h>\n\n#include <fstream>\n",
        "#include <dirent.h>\n#include <fcntl.h>\n#include <sys/stat.h>\n#include <unistd.h>\n\n#include <algorithm>\n#include <cctype>\n#include <cerrno>\n#include <cstdlib>\n#include <filesystem>\n#include <fstream>\n",
    ),
    (
        "hide disable_avb2/fix_contexts/install_kernel and expose flashlight/modules",
        "  result.disable_avb2 = true;\n  result.fix_contexts = flag(TW_HAS_DATA_MEDIA);\n  const bool repack = flag(\"tw_has_boot_slots\") && flag(\"tw_has_repack_tools\");\n  result.install_ramdisk = repack && flag(\"tw_include_install_recovery_ramdisk\");\n  result.reflash_twrp =\n      repack && !flag(\"tw_no_flash_current_twrp\") && !flag(\"tw_is_vendor_boot_header_v3\");\n  result.install_kernel = repack;\n  result.unmap_super_devices = flag(\"tw_is_super\");\n  result.sideload = flag(TW_HAS_DATA_MEDIA);\n  return result;\n",
        dedent("""\
          result.disable_avb2 = false;
          result.fix_contexts = false;
          const bool repack = flag("tw_has_boot_slots") && flag("tw_has_repack_tools");
          result.install_ramdisk = repack && flag("tw_include_install_recovery_ramdisk");
          result.reflash_twrp =
              repack && !flag("tw_no_flash_current_twrp") && !flag("tw_is_vendor_boot_header_v3");
          result.install_kernel = false;
          result.unmap_super_devices = flag("tw_is_super");
          result.sideload = flag(TW_HAS_DATA_MEDIA);
          result.flashlight = TWFunc::IsPathExists("/sys/class/leds/led:switch_2/brightness") ||
                              TWFunc::IsPathExists("/sys/class/leds/led:torch_0/brightness");
          result.modules = true;
          return result;
        """),
    ),
    (
        "implement flashlight and module manager methods",
        "void twrp_tools_backend::acknowledge() {\n  join_finished_thread();\n  std::lock_guard<std::mutex> lock(mutex_);\n  if (state_ != tool_state::RUNNING) state_ = tool_state::IDLE;\n}\n",
        dedent("""\
        void twrp_tools_backend::acknowledge() {
          join_finished_thread();
          std::lock_guard<std::mutex> lock(mutex_);
          if (state_ != tool_state::RUNNING) state_ = tool_state::IDLE;
        }

        namespace {

        constexpr const char* kFlashSwitchPath = "/sys/class/leds/led:switch_2/brightness";
        constexpr const char* kFlashTorch0Path = "/sys/class/leds/led:torch_0/brightness";
        constexpr const char* kFlashTorch0MaxPath = "/sys/class/leds/led:torch_0/max_brightness";
        constexpr const char* kFlashSecondaryTorchPaths[] = {
            "/sys/class/leds/led:torch_1/brightness",
            "/sys/class/leds/led:torch_2/brightness",
            "/sys/class/leds/led:torch_3/brightness",
        };
        // 10-step perceptual curve (10%..100%) scaled for led:torch_0 max_brightness=500.
        constexpr int kFlashTorchCurve[10] = {5, 12, 22, 38, 60, 95, 145, 220, 340, 500};
        constexpr const char* kModulesRoot = "/data/adb/modules";

        int read_sysfs_int(const char* path, int fallback) {
          std::ifstream in(path);
          int val = fallback;
          if (!(in >> val)) return fallback;
          return val;
        }

        bool write_sysfs_str(const char* path, const std::string& val) {
          const int fd = open(path, O_WRONLY | O_CLOEXEC);
          if (fd < 0) return false;
          const std::string payload = val + "\\n";
          const ssize_t written = write(fd, payload.data(), payload.size());
          close(fd);
          return written == static_cast<ssize_t>(payload.size());
        }

        int read_max_torch() {
          const int v = read_sysfs_int(kFlashTorch0MaxPath, 500);
          return v > 0 ? v : 500;
        }

        int step_to_hw(int step, int max_hw) {
          const int idx = std::clamp(step, 1, 10) - 1;
          const int clamped_max = std::max(1, max_hw);
          if (clamped_max == 500) return kFlashTorchCurve[idx];
          const int scaled = (kFlashTorchCurve[idx] * clamped_max + 250) / 500;
          return std::clamp(scaled, 1, clamped_max);
        }

        int hw_to_step(int hw, int max_hw) {
          int best_step = 1;
          int best_diff = std::abs(hw - step_to_hw(1, max_hw));
          for (int s = 2; s <= 10; ++s) {
            const int diff = std::abs(hw - step_to_hw(s, max_hw));
            if (diff < best_diff) {
              best_diff = diff;
              best_step = s;
            }
          }
          return best_step;
        }

        bool is_safe_module_id(const std::string& id) {
          if (id.empty() || id == "." || id == ".." || id == "lost+found") return false;
          if (id.find('/') != std::string::npos || id.find('\\0') != std::string::npos) return false;
          const std::string full = std::string(kModulesRoot) + "/" + id;
          struct stat st {};
          return lstat(full.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
        }

        std::string trim_copy(std::string s) {
          while (!s.empty() && (s.back() == '\\r' || s.back() == '\\n' || s.back() == ' ' || s.back() == '\\t'))
            s.pop_back();
          size_t start = 0;
          while (start < s.size() && (s[start] == ' ' || s[start] == '\\t')) ++start;
          return start == 0 ? s : s.substr(start);
        }

        bool remove_dir_no_follow(const std::string& path) {
          struct stat st {};
          if (lstat(path.c_str(), &st) != 0) return errno == ENOENT;
          if (!S_ISDIR(st.st_mode)) {
            if (unlink(path.c_str()) == 0) return true;
            chmod(path.c_str(), 0600);
            return unlink(path.c_str()) == 0;
          }
          chmod(path.c_str(), 0700);
          DIR* dir = opendir(path.c_str());
          if (dir == nullptr) return false;
          bool ok = true;
          while (struct dirent* ent = readdir(dir)) {
            const std::string name = ent->d_name;
            if (name == "." || name == "..") continue;
            if (!remove_dir_no_follow(path + "/" + name)) ok = false;
          }
          closedir(dir);
          if (!ok) return false;
          return rmdir(path.c_str()) == 0;
        }

        }  // namespace

        bool twrp_tools_backend::flashlight_enabled() {
          if (access(kFlashSwitchPath, F_OK) == 0)
            return read_sysfs_int(kFlashSwitchPath, 0) > 0;
          return false;
        }

        int twrp_tools_backend::flashlight_step() {
          if (flashlight_enabled() && access(kFlashTorch0Path, F_OK) == 0) {
            const int max_hw = read_max_torch();
            const int cur = read_sysfs_int(kFlashTorch0Path, -1);
            if (cur > 0 && cur != step_to_hw(flashlight_step_, max_hw))
              flashlight_step_ = hw_to_step(cur, max_hw);
          }
          return std::clamp(flashlight_step_, 1, 10);
        }

        bool twrp_tools_backend::set_flashlight(bool enabled, int step) {
          flashlight_step_ = std::clamp(step, 1, 10);
          if (!enabled) {
            TWFunc::DisableFlashlight();
            return !flashlight_enabled();
          }
          const int hw = step_to_hw(flashlight_step_, read_max_torch());
          const std::string val = std::to_string(hw);
          if (access(kFlashSwitchPath, W_OK) == 0)
            (void)write_sysfs_str(kFlashSwitchPath, "0");
          for (const char* p : kFlashSecondaryTorchPaths) {
            if (access(p, W_OK) == 0) (void)write_sysfs_str(p, "0");
          }
          const bool torch_ok = access(kFlashTorch0Path, W_OK) == 0 &&
                                write_sysfs_str(kFlashTorch0Path, val);
          const bool sw_ok = access(kFlashSwitchPath, W_OK) == 0 &&
                             write_sysfs_str(kFlashSwitchPath, "1");
          return torch_ok && sw_ok;
        }

        void twrp_tools_backend::disable_flashlight() {
          TWFunc::DisableFlashlight();
        }

        bool twrp_tools_backend::data_ready_for_modules() {
          if (DataManager::GetIntValue(TW_IS_FBE)) {
            if (TWPartition::DataIsLocked()) return false;
          } else if (DataManager::GetIntValue(TW_IS_ENCRYPTED) != 0 &&
                     DataManager::GetIntValue(TW_IS_DECRYPTED) == 0) {
            return false;
          }
          TWPartition* data = PartitionManager.FindPartitionByPath("/data");
          if (data != nullptr && !data->IsMounted()) data->Mount(false);
          return data != nullptr && data->IsMounted();
        }

        std::vector<module_entry> twrp_tools_backend::list_modules() {
          std::vector<module_entry> out;
          if (!data_ready_for_modules()) return out;
          DIR* dir = opendir(kModulesRoot);
          if (dir == nullptr) return out;
          while (struct dirent* ent = readdir(dir)) {
            const std::string id = ent->d_name;
            if (!is_safe_module_id(id)) continue;
            module_entry item;
            item.id = id;
            item.name = id;
            const std::string mod_dir = std::string(kModulesRoot) + "/" + id;
            struct stat disable_st {};
            item.enabled = lstat((mod_dir + "/disable").c_str(), &disable_st) != 0;
            std::ifstream prop(mod_dir + "/module.prop");
            std::string line;
            while (std::getline(prop, line)) {
              const size_t eq = line.find('=');
              if (eq == std::string::npos) continue;
              const std::string k = trim_copy(line.substr(0, eq));
              const std::string v = trim_copy(line.substr(eq + 1));
              if (k == "name" && !v.empty()) item.name = v;
              else if (k == "version" && !v.empty()) item.version = v;
            }
            out.push_back(std::move(item));
          }
          closedir(dir);
          std::sort(out.begin(), out.end(), [](const module_entry& a, const module_entry& b) {
            auto ci_less = [](const std::string& x, const std::string& y) {
              const size_t n = std::min(x.size(), y.size());
              for (size_t i = 0; i < n; ++i) {
                const unsigned char cx = static_cast<unsigned char>(std::tolower(static_cast<unsigned char>(x[i])));
                const unsigned char cy = static_cast<unsigned char>(std::tolower(static_cast<unsigned char>(y[i])));
                if (cx != cy) return cx < cy;
              }
              return x.size() < y.size();
            };
            if (ci_less(a.name, b.name)) return true;
            if (ci_less(b.name, a.name)) return false;
            return a.id < b.id;
          });
          return out;
        }

        bool twrp_tools_backend::set_module_enabled(const std::string& id, bool enabled) {
          if (!data_ready_for_modules() || !is_safe_module_id(id)) return false;
          const std::string flag_path = std::string(kModulesRoot) + "/" + id + "/disable";
          if (enabled) {
            return unlink(flag_path.c_str()) == 0 || errno == ENOENT;
          }
          struct stat st {};
          if (lstat(flag_path.c_str(), &st) == 0) return true;
          const int fd = open(flag_path.c_str(), O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0644);
          if (fd < 0) return false;
          close(fd);
          return true;
        }

        int twrp_tools_backend::disable_all_modules() {
          if (!data_ready_for_modules()) return -1;
          const auto items = list_modules();
          int changed = 0;
          for (const auto& item : items) {
            if (set_module_enabled(item.id, false)) ++changed;
          }
          return changed;
        }

        bool twrp_tools_backend::delete_module(const std::string& id) {
          if (!data_ready_for_modules() || !is_safe_module_id(id)) return false;
          return remove_dir_no_follow(std::string(kModulesRoot) + "/" + id);
        }
        """),
    ),
])

# 3. GUI2 new subpages: FLASHLIGHT & MODULES (components, i18n, routing, wiring)
write_new_file("bootable/recovery/gui2/pages/flashlight_page.h", """\
    #ifndef GUI2_PAGES_FLASHLIGHT_PAGE_H
    #define GUI2_PAGES_FLASHLIGHT_PAGE_H

    #include "components/slider.h"
    #include "core/ui_metrics.h"
    #include "i18n/i18n.h"
    #include "lvgl.h"

    namespace gui2_pages {

    struct flashlight_page_options {
      lv_obj_t* content = nullptr;
      const gui2_core::ui_metrics* metrics = nullptr;
      const gui2_i18n::language_pack* strings = nullptr;
      bool enabled = false;
      int step = 10;
      gui2_components::slider* slider_visual = nullptr;
      lv_obj_t** value_label = nullptr;
      lv_event_cb_t toggle_callback = nullptr;
      lv_event_cb_t brightness_callback = nullptr;
      lv_event_cb_t slider_pressed_callback = nullptr;
    };

    struct flashlight_page_view {
      lv_obj_t* body = nullptr;
      lv_obj_t* error_label = nullptr;
      lv_obj_t* toggle = nullptr;
      lv_obj_t* slider_card = nullptr;
    };

    flashlight_page_view build_flashlight_page(const flashlight_page_options& options);

    }  // namespace gui2_pages

    #endif
    """)

write_new_file("bootable/recovery/gui2/pages/flashlight_page.cpp", """\
    #include "pages/flashlight_page.h"

    #include <algorithm>

    #include "components/check_row.h"
    #include "components/slider_card.h"
    #include "core/ui_helpers.h"

    namespace gui2_pages {

    flashlight_page_view build_flashlight_page(const flashlight_page_options& options) {
      flashlight_page_view view;
      if (options.content == nullptr || options.metrics == nullptr || options.strings == nullptr ||
          options.slider_visual == nullptr || options.value_label == nullptr)
        return view;

      const auto& metrics = *options.metrics;
      const auto& strings = *options.strings;
      const int step = std::clamp(options.step, 1, 10);

      view.body = lv_obj_create(options.content);
      lv_obj_set_pos(view.body, metrics.content_left, 0);
      lv_obj_set_width(view.body, metrics.content_width);
      lv_obj_set_height(view.body, LV_SIZE_CONTENT);
      gui2_core::set_surface_style(view.body, metrics.background, LV_OPA_TRANSP);
      lv_obj_set_style_pad_all(view.body, 0, LV_PART_MAIN);
      lv_obj_set_style_pad_top(view.body, gui2_core::ui_px(8), LV_PART_MAIN);
      lv_obj_set_style_pad_row(view.body, metrics.card_gap, LV_PART_MAIN);
      lv_obj_set_layout(view.body, LV_LAYOUT_FLEX);
      lv_obj_set_flex_flow(view.body, LV_FLEX_FLOW_COLUMN);
      lv_obj_set_flex_align(view.body, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START,
                            LV_FLEX_ALIGN_START);
      lv_obj_set_overflow_visible(view.body, true);
      gui2_core::disable_scrolling(view.body);

      view.error_label = lv_label_create(view.body);
      lv_label_set_text(view.error_label, strings.flashlight_error);
      lv_label_set_long_mode(view.error_label, LV_LABEL_LONG_WRAP);
      lv_obj_set_width(view.error_label, metrics.content_width);
      lv_obj_set_style_text_color(view.error_label, metrics.danger, LV_PART_MAIN);
      lv_obj_set_style_text_font(view.error_label, metrics.status_font, LV_PART_MAIN);
      lv_obj_set_hidden(view.error_label, true);

      view.toggle = gui2_components::create_switch_row(
          view.body, metrics, strings.flashlight_toggle, options.enabled,
          options.toggle_callback, nullptr);

      view.slider_card = gui2_components::create_slider_card(
          view.body, metrics, strings.flashlight_brightness, 1, 10, step,
          options.slider_visual, options.value_label, options.brightness_callback,
          options.slider_pressed_callback, nullptr);
      if (*options.value_label != nullptr)
        lv_label_set_text_fmt(*options.value_label, "%d%%", step * 10);

      return view;
    }

    }  // namespace gui2_pages
    """)

write_new_file("bootable/recovery/gui2/pages/modules_page.h", """\
    #ifndef GUI2_PAGES_MODULES_PAGE_H
    #define GUI2_PAGES_MODULES_PAGE_H

    #include <cstddef>
    #include <string>
    #include <vector>

    #include "backend/tools_backend.h"
    #include "core/ui_metrics.h"
    #include "i18n/i18n.h"
    #include "lvgl.h"

    namespace gui2_pages {

    struct modules_page_options {
      lv_obj_t* content = nullptr;
      const gui2_core::ui_metrics* metrics = nullptr;
      const gui2_i18n::language_pack* strings = nullptr;
      bool data_ready = false;
      const gui2_backend::module_entry* modules = nullptr;
      size_t module_count = 0;
      const int* module_indices = nullptr;
      const char* error_text = nullptr;
      lv_event_cb_t disable_all_callback = nullptr;
      lv_event_cb_t toggle_callback = nullptr;
      lv_event_cb_t delete_callback = nullptr;
      lv_event_cb_t press_guard_callback = nullptr;
    };

    struct module_row_view {
      lv_obj_t* toggle = nullptr;
      lv_obj_t* detail_label = nullptr;
      lv_obj_t* delete_button = nullptr;
    };

    struct modules_page_view {
      lv_obj_t* body = nullptr;
      lv_obj_t* error_tip = nullptr;
      std::vector<module_row_view> rows;
    };

    std::string format_module_detail(const gui2_backend::module_entry& entry,
                                     const gui2_i18n::language_pack& strings);
    modules_page_view build_modules_page(const modules_page_options& options);

    }  // namespace gui2_pages

    #endif
    """)

write_new_file("bootable/recovery/gui2/pages/modules_page.cpp", """\
    #include "pages/modules_page.h"

    #include <algorithm>

    #include "components/flat_button.h"
    #include "components/icon.h"
    #include "components/section_label.h"
    #include "components/tip_card.h"
    #include "core/ui_helpers.h"
    #include "gui2_svg_assets.h"

    namespace gui2_pages {

    namespace {

    int card_side_padding(const gui2_core::ui_metrics& metrics) {
      return std::clamp(metrics.outer_margin, gui2_core::ui_px(32), gui2_core::ui_px(56));
    }

    lv_obj_t* create_module_switch(lv_obj_t* parent, const gui2_core::ui_metrics& metrics,
                                   bool checked, lv_event_cb_t callback, void* user_data) {
      const int row_height = std::max(metrics.card_height, gui2_core::ui_px(132));
      const int track_width = std::clamp(row_height * 60 / 100, gui2_core::ui_px(84), gui2_core::ui_px(124));
      const int track_height = std::clamp(track_width * 56 / 100, gui2_core::ui_px(48), gui2_core::ui_px(70));
      lv_obj_t* toggle = lv_switch_create(parent);
      lv_obj_set_size(toggle, track_width, track_height);
      lv_obj_set_style_radius(toggle, LV_RADIUS_CIRCLE, LV_PART_MAIN);
      lv_obj_set_style_bg_opa(toggle, LV_OPA_COVER, LV_PART_MAIN);
      lv_obj_set_style_bg_color(toggle, lv_color_mix(metrics.secondary_text, metrics.card_color, 110),
                                LV_PART_MAIN);
      lv_obj_set_style_border_width(toggle, 0, LV_PART_MAIN);
      lv_obj_set_style_shadow_width(toggle, 0, LV_PART_MAIN);
      lv_obj_set_style_radius(toggle, LV_RADIUS_CIRCLE, LV_PART_INDICATOR);
      lv_obj_set_style_bg_opa(toggle, LV_OPA_TRANSP, LV_PART_INDICATOR);
      lv_obj_set_style_bg_opa(toggle, LV_OPA_COVER, LV_PART_INDICATOR | LV_STATE_CHECKED);
      lv_obj_set_style_bg_color(toggle, metrics.accent, LV_PART_INDICATOR | LV_STATE_CHECKED);
      lv_obj_set_style_radius(toggle, LV_RADIUS_CIRCLE, LV_PART_KNOB);
      lv_obj_set_style_bg_opa(toggle, LV_OPA_COVER, LV_PART_KNOB);
      lv_obj_set_style_bg_color(toggle, metrics.on_accent, LV_PART_KNOB);
      lv_obj_set_style_pad_all(toggle, -gui2_core::ui_px(6), LV_PART_KNOB);
      lv_obj_set_style_shadow_width(toggle, 0, LV_PART_KNOB);
      if (checked) lv_obj_add_state(toggle, LV_STATE_CHECKED);
      if (callback != nullptr)
        lv_obj_add_event_cb(toggle, callback, LV_EVENT_VALUE_CHANGED, user_data);
      return toggle;
    }

    }  // namespace

    std::string format_module_detail(const gui2_backend::module_entry& entry,
                                     const gui2_i18n::language_pack& strings) {
      std::string detail;
      if (entry.name != entry.id) detail = entry.id;
      if (!entry.version.empty()) {
        if (!detail.empty()) detail += " · ";
        detail += entry.version;
      }
      if (!detail.empty()) detail += " · ";
      detail += entry.enabled ? strings.modules_enabled : strings.modules_disabled;
      return detail;
    }

    modules_page_view build_modules_page(const modules_page_options& options) {
      modules_page_view view;
      if (options.content == nullptr || options.metrics == nullptr || options.strings == nullptr)
        return view;

      const auto& metrics = *options.metrics;
      const auto& strings = *options.strings;

      view.body = lv_obj_create(options.content);
      lv_obj_set_pos(view.body, metrics.content_left, 0);
      lv_obj_set_width(view.body, metrics.content_width);
      lv_obj_set_height(view.body, LV_SIZE_CONTENT);
      gui2_core::set_surface_style(view.body, metrics.background, LV_OPA_TRANSP);
      lv_obj_set_style_pad_all(view.body, 0, LV_PART_MAIN);
      lv_obj_set_style_pad_row(view.body, metrics.card_gap, LV_PART_MAIN);
      lv_obj_set_layout(view.body, LV_LAYOUT_FLEX);
      lv_obj_set_flex_flow(view.body, LV_FLEX_FLOW_COLUMN);
      lv_obj_set_flex_align(view.body, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START,
                            LV_FLEX_ALIGN_START);
      gui2_core::disable_scrolling(view.body);

      if (options.error_text != nullptr && options.error_text[0] != '\\0') {
        view.error_tip = gui2_components::create_tip_card(
            view.body, metrics, options.error_text, metrics.danger, metrics.danger_surface);
      }

      if (!options.data_ready) {
        gui2_components::create_tip_card(view.body, metrics, strings.modules_decrypt_first,
                                         metrics.warning, metrics.warning_surface);
        return view;
      }

      if (options.module_count == 0 || options.modules == nullptr || options.module_indices == nullptr) {
        gui2_components::create_tip_card(view.body, metrics, strings.modules_empty,
                                         metrics.secondary_text, metrics.card_color);
        return view;
      }

      gui2_components::create_flat_button(view.body, metrics, metrics.content_width,
                                          strings.modules_disable_all,
                                          options.disable_all_callback,
                                          options.press_guard_callback);

      view.rows.resize(options.module_count);
      const int card_min_h = std::max(metrics.card_height, gui2_core::ui_px(132));
      const int side_pad = card_side_padding(metrics);
      const int vert_pad = gui2_core::ui_px(20);
      const int del_size = gui2_core::ui_px(68);
      const int icon_size = gui2_core::ui_px(30);

      for (size_t i = 0; i < options.module_count; ++i) {
        const auto& mod = options.modules[i];
        void* idx_data = const_cast<void*>(static_cast<const void*>(&options.module_indices[i]));

        lv_obj_t* card = lv_obj_create(view.body);
        lv_obj_set_width(card, metrics.content_width);
        lv_obj_set_height(card, LV_SIZE_CONTENT);
        lv_obj_set_style_min_height(card, card_min_h, LV_PART_MAIN);
        gui2_core::set_surface_style(card, metrics.card_color);
        lv_obj_set_style_radius(card, card_min_h / 4, LV_PART_MAIN);
        lv_obj_set_style_pad_left(card, side_pad, LV_PART_MAIN);
        lv_obj_set_style_pad_right(card, side_pad, LV_PART_MAIN);
        lv_obj_set_style_pad_top(card, vert_pad, LV_PART_MAIN);
        lv_obj_set_style_pad_bottom(card, vert_pad, LV_PART_MAIN);
        lv_obj_set_style_pad_column(card, gui2_core::ui_px(16), LV_PART_MAIN);
        gui2_core::set_card_shadow(card);
        gui2_core::disable_scrolling(card);
        lv_obj_set_layout(card, LV_LAYOUT_FLEX);
        lv_obj_set_flex_flow(card, LV_FLEX_FLOW_ROW);
        lv_obj_set_flex_align(card, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER,
                              LV_FLEX_ALIGN_CENTER);

        lv_obj_t* text_block = lv_obj_create(card);
        lv_obj_set_flex_grow(text_block, 1);
        lv_obj_set_width(text_block, 0);
        lv_obj_set_height(text_block, LV_SIZE_CONTENT);
        gui2_core::set_surface_style(text_block, metrics.background, LV_OPA_TRANSP);
        lv_obj_set_style_pad_all(text_block, 0, LV_PART_MAIN);
        lv_obj_set_style_pad_row(text_block, gui2_core::ui_px(6), LV_PART_MAIN);
        lv_obj_set_layout(text_block, LV_LAYOUT_FLEX);
        lv_obj_set_flex_flow(text_block, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_flex_align(text_block, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START,
                              LV_FLEX_ALIGN_START);
        lv_obj_set_clickable(text_block, false);
        gui2_core::disable_scrolling(text_block);

        lv_obj_t* title = lv_label_create(text_block);
        lv_label_set_text(title, mod.name.c_str());
        lv_label_set_long_mode(title, LV_LABEL_LONG_WRAP);
        lv_obj_set_width(title, lv_pct(100));
        lv_obj_set_style_text_color(title, metrics.primary_text, LV_PART_MAIN);
        lv_obj_set_style_text_font(title, metrics.text_font, LV_PART_MAIN);

        const std::string detail_str = format_module_detail(mod, strings);
        lv_obj_t* detail = lv_label_create(text_block);
        lv_label_set_text(detail, detail_str.c_str());
        lv_label_set_long_mode(detail, LV_LABEL_LONG_WRAP);
        lv_obj_set_width(detail, lv_pct(100));
        lv_obj_set_style_text_font(detail, metrics.status_font, LV_PART_MAIN);
        lv_obj_set_style_text_color(
            detail, mod.enabled ? metrics.success : metrics.secondary_text, LV_PART_MAIN);

        lv_obj_t* del_btn = lv_obj_create(card);
        lv_obj_set_size(del_btn, del_size, del_size);
        gui2_core::set_surface_style(del_btn, metrics.danger_surface_soft);
        lv_obj_set_style_bg_color(del_btn, gui2_core::tinted(metrics.danger_surface_soft, 24),
                                  LV_STATE_PRESSED);
        lv_obj_set_style_radius(del_btn, gui2_core::ui_px(20), LV_PART_MAIN);
        lv_obj_set_style_pad_all(del_btn, 0, LV_PART_MAIN);
        lv_obj_set_clickable(del_btn, true);
        gui2_core::disable_scrolling(del_btn);
        if (options.press_guard_callback != nullptr)
          lv_obj_add_event_cb(del_btn, options.press_guard_callback, LV_EVENT_ALL, nullptr);
        if (options.delete_callback != nullptr)
          lv_obj_add_event_cb(del_btn, options.delete_callback, LV_EVENT_CLICKED, idx_data);

        lv_obj_t* del_icon = gui2_components::create_svg_image(
            del_btn, &kGui2IconClose, icon_size, icon_size);
        if (del_icon != nullptr) {
          lv_obj_center(del_icon);
          lv_obj_set_style_image_recolor(del_icon, metrics.danger, LV_PART_MAIN);
          lv_obj_set_style_image_recolor_opa(del_icon, LV_OPA_COVER, LV_PART_MAIN);
          lv_obj_set_clickable(del_icon, false);
        }

        lv_obj_t* toggle = create_module_switch(
            card, metrics, mod.enabled, options.toggle_callback, idx_data);
        view.rows[i] = { toggle, detail, del_btn };
      }

      return view;
    }

    }  // namespace gui2_pages
    """)

patch_file("bootable/recovery/gui2/Android.bp", [
    (
        "compile flashlight_page.cpp and modules_page.cpp",
        "        \"pages/timezone_page.cpp\",\n",
        "        \"pages/timezone_page.cpp\",\n        \"pages/flashlight_page.cpp\",\n        \"pages/modules_page.cpp\",\n",
    ),
])

patch_file("bootable/recovery/gui2/pages/page_router.h", [
    (
        "add FLASHLIGHT and MODULES page_id",
        "  TOOL_PROGRESS,\n  TOOL_INPUT,\n};\n",
        "  TOOL_PROGRESS,\n  TOOL_INPUT,\n  FLASHLIGHT,\n  MODULES,\n};\n",
    ),
])

patch_file("bootable/recovery/gui2/pages/page_state.h", [
    (
        "include flashlight_page.h and modules_page.h",
        "#include \"pages/reboot_page.h\"\n",
        "#include \"backend/tools_backend.h\"\n#include \"pages/flashlight_page.h\"\n#include \"pages/modules_page.h\"\n#include \"pages/reboot_page.h\"\n",
    ),
    (
        "add flashlight and modules state",
        "  reboot_page_state reboot;\n};\n",
        dedent("""\
          reboot_page_state reboot;
          bool flashlight_enabled = false;
          int flashlight_step = 10;
          gui2_components::slider flashlight_slider;
          lv_obj_t* flashlight_value_label = nullptr;
          flashlight_page_view flashlight_view;
          modules_page_view modules_view;
          std::vector<gui2_backend::module_entry> modules_list;
          std::string pending_module_delete;
          std::string modules_error;
        };
        """),
    ),
])

patch_file("bootable/recovery/gui2/pages/advanced_page.h", [
    (
        "add flashlight_target and modules_target",
        "  const void* export_log_target = nullptr;\n",
        "  const void* export_log_target = nullptr;\n  const void* flashlight_target = nullptr;\n  const void* modules_target = nullptr;\n",
    ),
])

patch_file("bootable/recovery/gui2/pages/advanced_page.cpp", [
    (
        "render flashlight and modules cards",
        "  const auto& strings = *options.strings;\n  add(options.twrp_folder_target, strings.twrp_folder_title, options.twrp_folder_detail);\n",
        dedent("""\
          const auto& strings = *options.strings;
          add(options.flashlight_target, strings.flashlight_title, strings.flashlight_summary);
          add(options.modules_target, strings.modules_title, strings.modules_summary);
          add(options.twrp_folder_target, strings.twrp_folder_title, options.twrp_folder_detail);
        """),
    ),
])

patch_file("bootable/recovery/gui2/i18n/i18n.h", [
    (
        "add i18n keys for flashlight and modules",
        "  const char* zip_err;\n  const char* zip_wipe_cache;\n};\n",
        dedent("""\
          const char* zip_err;
          const char* zip_wipe_cache;
          const char* flashlight_title;
          const char* flashlight_summary;
          const char* flashlight_toggle;
          const char* flashlight_brightness;
          const char* flashlight_error;
          const char* modules_title;
          const char* modules_summary;
          const char* modules_decrypt_first;
          const char* modules_empty;
          const char* modules_enabled;
          const char* modules_disabled;
          const char* modules_disable_all;
          const char* modules_disable_all_confirm_title;
          const char* modules_disable_all_confirm_body;
          const char* modules_delete_confirm_title;
          const char* modules_delete_confirm_body;
          const char* modules_delete_confirm_action;
          const char* modules_action_error;
        };
        """),
    ),
])

i18n_translations = {
    "bootable/recovery/gui2/i18n/en.cpp": [
        "Flashlight",
        "Toggle camera flash LED and adjust torch brightness",
        "Flashlight",
        "Brightness",
        "Unable to control flashlight LED",
        "Modules",
        "Manage Magisk, KernelSU and APatch modules",
        "Decrypt /data first to manage modules",
        "No modules found in /data/adb/modules",
        "Enabled",
        "Disabled",
        "Disable all modules",
        "Disable all modules?",
        "A disable flag will be created for all installed modules in /data/adb/modules.",
        "Delete module?",
        "Permanently delete module \"%s\" from /data/adb/modules?",
        "Delete",
        "Module operation failed",
    ],
    "bootable/recovery/gui2/i18n/zh_cn.cpp": [
        "手电筒",
        "开关闪光灯并调节手电筒亮度",
        "开启手电筒",
        "亮度",
        "无法控制手电筒 LED",
        "模块管理",
        "管理 Magisk / KernelSU / APatch 模块",
        "请先解密 /data 分区后再管理模块",
        "未在 /data/adb/modules 中找到模块",
        "已启用",
        "已禁用",
        "禁用所有模块",
        "禁用所有模块？",
        "将为 /data/adb/modules 中的所有模块创建 disable 标记文件。",
        "删除模块？",
        "确定要从 /data/adb/modules 永久删除模块“%s”吗？",
        "删除",
        "模块操作失败",
    ],
    "bootable/recovery/gui2/i18n/zh_tw.cpp": [
        "手電筒",
        "開關閃光燈並調整手電筒亮度",
        "開啟手電筒",
        "亮度",
        "無法控制手電筒 LED",
        "模組管理",
        "管理 Magisk / KernelSU / APatch 模組",
        "請先解密 /data 分割區後再管理模組",
        "未在 /data/adb/modules 中找到模組",
        "已啟用",
        "已停用",
        "停用所有模組",
        "停用所有模組？",
        "將為 /data/adb/modules 中的所有模組建立 disable 標記檔案。",
        "刪除模組？",
        "確定要從 /data/adb/modules 永久刪除模組「%s」嗎？",
        "刪除",
        "模組操作失敗",
    ],
    "bootable/recovery/gui2/i18n/ru.cpp": [
        "Фонарик",
        "Включение вспышки и регулировка яркости",
        "Фонарик",
        "Яркость",
        "Не удалось управлять светодиодом вспышки",
        "Модули",
        "Управление модулями Magisk / KernelSU / APatch",
        "Сначала расшифруйте /data",
        "Модули не найдены (/data/adb/modules)",
        "Включён",
        "Отключён",
        "Отключить все модули",
        "Отключить все модули?",
        "Для всех модулей в /data/adb/modules будет создан файл disable.",
        "Удалить модуль?",
        "Удалить модуль «%s» из /data/adb/modules безвозвратно?",
        "Удалить",
        "Ошибка операции с модулем",
    ],
}
for path_str, items in i18n_translations.items():
    block = "\n".join('  "{}",'.format(s.replace('\\', '\\\\').replace('"', '\\"')) for s in items) + "\n};"
    patch_file(path_str, [("append Step E strings", "\n};", "\n" + block)])

# 4. gui2.cpp Step D fixes + Step E FLASHLIGHT & MODULES pages + flashlight shutdown guard
patch_file("bootable/recovery/gui2/gui2.cpp", [
    (
        "include flashlight_page.h and modules_page.h",
        "#include \"pages/wipe_page.h\"\n",
        "#include \"pages/flashlight_page.h\"\n#include \"pages/modules_page.h\"\n#include \"pages/wipe_page.h\"\n",
    ),
    (
        "declare show_flashlight_page and show_modules_page",
        "static void show_fastbootd_page(page_transition transition);\n",
        "static void show_fastbootd_page(page_transition transition);\nstatic void show_flashlight_page(page_transition transition);\nstatic void show_modules_page(page_transition transition);\n",
    ),
    (
        "add settings_target::FLASHLIGHT and settings_target::MODULES",
        "  UNMAP_SUPER,\n};\n",
        "  UNMAP_SUPER,\n  FLASHLIGHT,\n  MODULES,\n};\n",
    ),
    (
        "add target instances for FLASHLIGHT and MODULES",
        "static constexpr settings_target unmap_super_target = settings_target::UNMAP_SUPER;\n",
        "static constexpr settings_target unmap_super_target = settings_target::UNMAP_SUPER;\nstatic constexpr settings_target flashlight_target = settings_target::FLASHLIGHT;\nstatic constexpr settings_target modules_target = settings_target::MODULES;\n",
    ),
    (
        "handle navigate_back for FLASHLIGHT and MODULES",
        "  } else if (page_router.current() == page_kind::EXPORT_LOG) {\n",
        "  } else if (page_router.current() == page_kind::FLASHLIGHT ||\n             page_router.current() == page_kind::MODULES) {\n    navigate_to(page_kind::ACTION, advanced_definition(), page_transition::POP);\n  } else if (page_router.current() == page_kind::EXPORT_LOG) {\n",
    ),
    (
        "reset flashlight/modules transient views in create_page_scaffold",
        "  page_state.kernel_log_card = nullptr;\n  page_state.logcat_card = nullptr;\n",
        "  page_state.kernel_log_card = nullptr;\n  page_state.logcat_card = nullptr;\n  page_state.flashlight_view = {};\n  page_state.flashlight_value_label = nullptr;\n  page_state.modules_view = {};\n",
    ),
    (
        "route settings_option_event_cb to FLASHLIGHT and MODULES",
        "  else if (*target == settings_target::EXPORT_LOG)\n    navigate_to(page_kind::EXPORT_LOG);\n",
        "  else if (*target == settings_target::EXPORT_LOG)\n    navigate_to(page_kind::EXPORT_LOG);\n  else if (*target == settings_target::FLASHLIGHT)\n    navigate_to(page_kind::FLASHLIGHT);\n  else if (*target == settings_target::MODULES)\n    navigate_to(page_kind::MODULES);\n",
    ),
    (
        "backup_option_event_cb scroll settle+clamp",
        "  else if (*target == kBackupEncryptTarget) {\n    page_state.backup_encrypt = checked;\n    gui2_pages::show_backup_password(page_state.backup_view, checked);\n  }\n",
        "  else if (*target == kBackupEncryptTarget) {\n    const int scroll_y = main_content == nullptr ? 0 : lv_obj_get_scroll_y(main_content);\n    page_state.backup_encrypt = checked;\n    gui2_pages::show_backup_password(page_state.backup_view, checked);\n    if (main_content != nullptr) lv_obj_scroll_to_y(main_content, 0, LV_ANIM_OFF);\n    page_host.settle();\n    if (main_content != nullptr && lv_obj_has_flag(main_content, LV_OBJ_FLAG_SCROLLABLE)) {\n      const int max_scroll = std::max(0, static_cast<int>(lv_obj_get_scroll_bottom(main_content)));\n      lv_obj_scroll_to_y(main_content, std::clamp(scroll_y, 0, max_scroll), LV_ANIM_OFF);\n    }\n  }\n",
    ),
    (
        "backup_tab_changed scroll reset + settle",
        "static void backup_tab_changed(size_t index, void*) {\n  page_state.backup_active_tab = index;\n  gui2_pages::show_backup_tab(page_state.backup_view, index);\n  if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::BUTTON);\n}\n",
        "static void backup_tab_changed(size_t index, void*) {\n  page_state.backup_active_tab = index;\n  gui2_pages::show_backup_tab(page_state.backup_view, index);\n  if (main_content != nullptr) lv_obj_scroll_to_y(main_content, 0, LV_ANIM_OFF);\n  page_host.settle();\n  if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::BUTTON);\n}\n",
    ),
    (
        "restore_tab_changed scroll reset + settle",
        "static void restore_tab_changed(size_t index, void*) {\n  page_state.restore_active_tab = index;\n  gui2_pages::show_restore_tab(page_state.restore_view, index);\n  if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::BUTTON);\n}\n",
        "static void restore_tab_changed(size_t index, void*) {\n  page_state.restore_active_tab = index;\n  gui2_pages::show_restore_tab(page_state.restore_view, index);\n  if (main_content != nullptr) lv_obj_scroll_to_y(main_content, 0, LV_ANIM_OFF);\n  page_host.settle();\n  if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::BUTTON);\n}\n",
    ),
    (
        "gate tw_auto_disable_avb2",
        "  add(nullptr, text.general_disable_avb2, \"tw_auto_disable_avb2\");\n",
        "  if (tools != nullptr && tools->availability().disable_avb2)\n    add(nullptr, text.general_disable_avb2, \"tw_auto_disable_avb2\");\n",
    ),
    (
        "wire flashlight_target and modules_target in advanced_options",
        "    advanced_options.unmap_super_target =\n        available.unmap_super_devices ? &unmap_super_target : nullptr;\n",
        dedent("""\
              advanced_options.unmap_super_target =
                  available.unmap_super_devices ? &unmap_super_target : nullptr;
              advanced_options.flashlight_target =
                  available.flashlight ? &flashlight_target : nullptr;
              advanced_options.modules_target =
                  available.modules ? &modules_target : nullptr;
        """),
    ),
    (
        "define flashlight and modules page builders and callbacks",
        "static void show_export_log_page(page_transition transition) {\n",
        dedent("""\
        static void set_flashlight_error_visible(bool visible) {
          if (page_state.flashlight_view.error_label != nullptr)
            lv_obj_set_hidden(page_state.flashlight_view.error_label, !visible);
        }

        static void flashlight_toggle_cb(lv_event_t* event) {
          if (lv_event_get_code(event) != LV_EVENT_VALUE_CHANGED || tools == nullptr) return;
          lv_obj_t* toggle = static_cast<lv_obj_t*>(lv_event_get_target(event));
          if (toggle == nullptr) return;
          const bool want = lv_obj_has_state(toggle, LV_STATE_CHECKED);
          const bool ok = tools->set_flashlight(want, page_state.flashlight_step);
          page_state.flashlight_enabled = tools->flashlight_enabled();
          if (!ok) {
            if (page_state.flashlight_enabled)
              lv_obj_add_state(toggle, LV_STATE_CHECKED);
            else
              lv_obj_clear_state(toggle, LV_STATE_CHECKED);
          }
          set_flashlight_error_visible(!ok);
          if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::BUTTON);
        }

        static void flashlight_slider_pressed_cb(lv_event_t*) {
          gui2_components::refresh_slider(&page_state.flashlight_slider);
        }

        static void flashlight_slider_cb(lv_event_t* event) {
          const lv_event_code_t code = lv_event_get_code(event);
          if (code == LV_EVENT_VALUE_CHANGED) {
            const int step = std::clamp(gui2_components::get_value(&page_state.flashlight_slider), 1, 10);
            page_state.flashlight_step = step;
            if (page_state.flashlight_value_label != nullptr)
              lv_label_set_text_fmt(page_state.flashlight_value_label, "%d%%", step * 10);
            gui2_components::refresh_slider(&page_state.flashlight_slider);
            bool ok = true;
            if (tools != nullptr && (page_state.flashlight_enabled || tools->flashlight_enabled())) {
              ok = tools->set_flashlight(true, step);
              page_state.flashlight_enabled = tools->flashlight_enabled();
            }
            set_flashlight_error_visible(!ok);
          } else if (code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST) {
            gui2_components::refresh_slider(&page_state.flashlight_slider);
          }
        }

        static void show_flashlight_page(page_transition transition) {
          create_page_scaffold(page_kind::FLASHLIGHT, false, strings().flashlight_title, "", 0,
                               transition);
          page_state.flashlight_view = {};
          page_state.flashlight_value_label = nullptr;
          page_state.flashlight_enabled = tools != nullptr && tools->flashlight_enabled();
          page_state.flashlight_step = tools != nullptr ? tools->flashlight_step() : 10;

          gui2_pages::flashlight_page_options options;
          options.content = main_content;
          options.metrics = &ui;
          options.strings = &strings();
          options.enabled = page_state.flashlight_enabled;
          options.step = page_state.flashlight_step;
          options.slider_visual = &page_state.flashlight_slider;
          options.value_label = &page_state.flashlight_value_label;
          options.toggle_callback = flashlight_toggle_cb;
          options.brightness_callback = flashlight_slider_cb;
          options.slider_pressed_callback = flashlight_slider_pressed_cb;
          page_state.flashlight_view = gui2_pages::build_flashlight_page(options);
        }

        static void dialog_dismiss_cb(lv_event_t* event) {
          if (lv_event_get_code(event) != LV_EVENT_CLICKED || !accept_click(event)) return;
          page_state.pending_module_delete.clear();
          auto* overlay = static_cast<lv_obj_t*>(lv_event_get_user_data(event));
          if (overlay != nullptr) lv_obj_delete(overlay);
        }

        static void modules_rebuild_preserving_scroll(int scroll_y) {
          navigate_to(page_kind::MODULES, nullptr, page_transition::REPLACE);
          if (main_content != nullptr && lv_obj_has_flag(main_content, LV_OBJ_FLAG_SCROLLABLE)) {
            const int max_scroll = std::max(0, static_cast<int>(lv_obj_get_scroll_bottom(main_content)));
            lv_obj_scroll_to_y(main_content, std::clamp(scroll_y, 0, max_scroll), LV_ANIM_OFF);
          }
        }

        static void modules_disable_all_confirm_cb(lv_event_t* event) {
          if (lv_event_get_code(event) != LV_EVENT_CLICKED || !accept_click(event)) return;
          auto* overlay = static_cast<lv_obj_t*>(lv_event_get_user_data(event));
          if (overlay != nullptr) lv_obj_delete(overlay);
          const int scroll_y = main_content == nullptr ? 0 : lv_obj_get_scroll_y(main_content);
          if (tools != nullptr) {
            const int count = tools->disable_all_modules();
            if (count < 0)
              page_state.modules_error = strings().modules_action_error;
            else
              page_state.modules_error.clear();
          }
          if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::ACTION);
          modules_rebuild_preserving_scroll(scroll_y);
        }

        static void modules_disable_all_cb(lv_event_t* event) {
          if (lv_event_get_code(event) != LV_EVENT_CLICKED || !accept_click(event)) return;
          gui2_shell::confirm_dialog_options opts;
          opts.metrics = &ui;
          opts.title = strings().modules_disable_all_confirm_title;
          opts.body = strings().modules_disable_all_confirm_body;
          opts.cancel = strings().cancel;
          opts.confirm = strings().apply;
          opts.cancel_callback = dialog_dismiss_cb;
          opts.confirm_callback = modules_disable_all_confirm_cb;
          opts.press_guard_callback = press_cancel_guard_cb;
          gui2_shell::create_confirm_dialog(opts);
        }

        static void modules_delete_confirm_cb(lv_event_t* event) {
          if (lv_event_get_code(event) != LV_EVENT_CLICKED || !accept_click(event)) return;
          auto* overlay = static_cast<lv_obj_t*>(lv_event_get_user_data(event));
          if (overlay != nullptr) lv_obj_delete(overlay);
          const std::string target_id = page_state.pending_module_delete;
          page_state.pending_module_delete.clear();
          const int scroll_y = main_content == nullptr ? 0 : lv_obj_get_scroll_y(main_content);
          if (tools != nullptr && !target_id.empty()) {
            if (!tools->delete_module(target_id))
              page_state.modules_error = strings().modules_action_error;
            else
              page_state.modules_error.clear();
          }
          if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::ACTION);
          modules_rebuild_preserving_scroll(scroll_y);
        }

        static void modules_delete_cb(lv_event_t* event) {
          if (lv_event_get_code(event) != LV_EVENT_CLICKED || !accept_click(event)) return;
          const auto* idx_ptr = static_cast<const int*>(lv_event_get_user_data(event));
          if (idx_ptr == nullptr || *idx_ptr < 0 ||
              static_cast<size_t>(*idx_ptr) >= page_state.modules_list.size())
            return;
          const auto& entry = page_state.modules_list[static_cast<size_t>(*idx_ptr)];
          page_state.pending_module_delete = entry.id;
          const std::string& label = entry.name.empty() ? entry.id : entry.name;
          const std::string body = format_text(strings().modules_delete_confirm_body, label);
          gui2_shell::confirm_dialog_options opts;
          opts.metrics = &ui;
          opts.title = strings().modules_delete_confirm_title;
          opts.body = body.c_str();
          opts.cancel = strings().cancel;
          opts.confirm = strings().modules_delete_confirm_action;
          opts.cancel_callback = dialog_dismiss_cb;
          opts.confirm_callback = modules_delete_confirm_cb;
          opts.press_guard_callback = press_cancel_guard_cb;
          gui2_shell::create_confirm_dialog(opts);
        }

        static void modules_toggle_cb(lv_event_t* event) {
          if (lv_event_get_code(event) != LV_EVENT_VALUE_CHANGED || tools == nullptr) return;
          const auto* idx_ptr = static_cast<const int*>(lv_event_get_user_data(event));
          lv_obj_t* toggle = static_cast<lv_obj_t*>(lv_event_get_target(event));
          if (idx_ptr == nullptr || toggle == nullptr || *idx_ptr < 0 ||
              static_cast<size_t>(*idx_ptr) >= page_state.modules_list.size())
            return;
          const size_t idx = static_cast<size_t>(*idx_ptr);
          auto& entry = page_state.modules_list[idx];
          const bool want = lv_obj_has_state(toggle, LV_STATE_CHECKED);
          const bool ok = tools->set_module_enabled(entry.id, want);
          if (ok) {
            entry.enabled = want;
            page_state.modules_error.clear();
            if (idx < page_state.modules_view.rows.size()) {
              auto& row = page_state.modules_view.rows[idx];
              if (row.detail_label != nullptr) {
                const std::string detail_str = gui2_pages::format_module_detail(entry, strings());
                lv_label_set_text(row.detail_label, detail_str.c_str());
                lv_obj_set_style_text_color(
                    row.detail_label, entry.enabled ? ui.success : ui.secondary_text,
                    LV_PART_MAIN);
              }
            }
            const int scroll_y = main_content == nullptr ? 0 : lv_obj_get_scroll_y(main_content);
            if (main_content != nullptr) lv_obj_scroll_to_y(main_content, 0, LV_ANIM_OFF);
            page_host.settle();
            if (main_content != nullptr && lv_obj_has_flag(main_content, LV_OBJ_FLAG_SCROLLABLE)) {
              const int max_scroll = std::max(0, static_cast<int>(lv_obj_get_scroll_bottom(main_content)));
              lv_obj_scroll_to_y(main_content, std::clamp(scroll_y, 0, max_scroll), LV_ANIM_OFF);
            }
          } else {
            if (want) lv_obj_clear_state(toggle, LV_STATE_CHECKED);
            else lv_obj_add_state(toggle, LV_STATE_CHECKED);
            page_state.modules_error = strings().modules_action_error;
            const int scroll_y = main_content == nullptr ? 0 : lv_obj_get_scroll_y(main_content);
            modules_rebuild_preserving_scroll(scroll_y);
          }
          if (hardware != nullptr) hardware->vibrate(gui2_backend::haptic_channel::BUTTON);
        }

        static void show_modules_page(page_transition transition) {
          create_page_scaffold(page_kind::MODULES, false, strings().modules_title, "", 0,
                               transition);
          page_state.modules_view = {};
          page_state.pending_module_delete.clear();
          const bool ready = tools != nullptr && tools->data_ready_for_modules();
          page_state.modules_list = ready ? tools->list_modules()
                                          : std::vector<gui2_backend::module_entry>();

          gui2_pages::modules_page_options options;
          options.content = main_content;
          options.metrics = &ui;
          options.strings = &strings();
          options.data_ready = ready;
          options.modules = page_state.modules_list.data();
          options.module_count = page_state.modules_list.size();
          options.module_indices = row_indices(page_state.modules_list.size());
          options.error_text = page_state.modules_error.empty() ? nullptr
                                                                : page_state.modules_error.c_str();
          options.disable_all_callback = modules_disable_all_cb;
          options.toggle_callback = modules_toggle_cb;
          options.delete_callback = modules_delete_cb;
          options.press_guard_callback = press_cancel_guard_cb;
          page_state.modules_view = gui2_pages::build_modules_page(options);
        }

        static void show_export_log_page(page_transition transition) {
        """),
    ),
    (
        "route FLASHLIGHT and MODULES in build_page",
        "    case page_kind::EXPORT_LOG:\n      show_export_log_page(request.transition);\n      return;\n",
        "    case page_kind::EXPORT_LOG:\n      show_export_log_page(request.transition);\n      return;\n    case page_kind::FLASHLIGHT:\n      show_flashlight_page(request.transition);\n      return;\n    case page_kind::MODULES:\n      show_modules_page(request.transition);\n      return;\n",
    ),
    (
        "disable flashlight on gui2 shutdown",
        "  if (background != nullptr) background->stop();\n",
        "  if (background != nullptr) background->stop();\n  if (tools != nullptr) tools->disable_flashlight();\n",
    ),
])

# 5. Restrict single-line textareas to horizontal scrolling so vertical swipe scrolls page
patch_file("bootable/recovery/gui2/pages/backup_page.cpp", [
    (
        "backup_page input LV_DIR_HOR",
        "  lv_obj_t* input = lv_textarea_create(parent);\n  lv_textarea_set_one_line(input, true);\n",
        "  lv_obj_t* input = lv_textarea_create(parent);\n  lv_textarea_set_one_line(input, true);\n  lv_obj_set_scroll_dir(input, LV_DIR_HOR);\n",
    ),
])
patch_file("bootable/recovery/gui2/pages/restore_page.cpp", [
    (
        "restore_page input LV_DIR_HOR",
        "    view.password_input = lv_textarea_create(view.options_pane);\n    lv_textarea_set_one_line(view.password_input, true);\n",
        "    view.password_input = lv_textarea_create(view.options_pane);\n    lv_textarea_set_one_line(view.password_input, true);\n    lv_obj_set_scroll_dir(view.password_input, LV_DIR_HOR);\n",
    ),
])

# 6. Suppress 4 Hz AIDL health fallback spam in battery_utils.cpp (log once, keep HIDL polling intact)
patch_file("bootable/recovery/recovery_utils/battery_utils.cpp", [
    (
        "log AIDL health fallback once",
        "  if (health == nullptr) {\n    LOG(INFO) << \"Unable to get AIDL health service, trying HIDL...\";\n",
        "  if (health == nullptr) {\n    static bool logged_aidl_unavailable = false;\n    if (!logged_aidl_unavailable) {\n      LOG(INFO) << \"Unable to get AIDL health service, trying HIDL...\";\n      logged_aidl_unavailable = true;\n    }\n",
    ),
])
