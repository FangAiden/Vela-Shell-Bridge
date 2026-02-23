import app from "@system.app";
import battery from "@system.battery";
import brightness from "@system.brightness";
import configuration from "@system.configuration";
import device from "@system.device";
import geolocation from "@system.geolocation";
import network from "@system.network";
import sensor from "@system.sensor";
import vibrator from "@system.vibrator";
import volume from "@system.volume";

import suIpc from "../../services/su-daemon/index.js";
import {
  clamp,
  compassFromDeg,
  formatBytes,
  mapAppSourceType,
  mapBrightnessMode,
  mapNetworkType,
  pickFirstNonEmpty,
  radToDeg,
  toPercent01,
  toPercent255
} from "./about-utils.js";

const QUICKAPP_ABS_BASE = "/data/files/";

export async function refreshBasicInfo(options = {}) {
  if (this.isRefreshingBasic) return;
  this.isRefreshingBasic = true;
  const keepY = this.currentScrollY || 0;
  const opt = options && typeof options === "object" ? options : {};
  const mode = typeof opt.mode === "string" ? opt.mode : "full";
  const isEnterMode = mode === "enter";
  const collectLocation =
    typeof opt.collectLocation === "boolean" ? opt.collectLocation : !isEnterMode;
  const collectSensors =
    typeof opt.collectSensors === "boolean" ? opt.collectSensors : !isEnterMode;

  const callSuccess = (fn, baseArgs, timeoutMs) =>
    new Promise((resolve, reject) => {
      let done = false;
      const t = setTimeout(() => {
        if (done) return;
        done = true;
        reject(new Error("timeout"));
      }, timeoutMs || 1500);

      const args = Object.assign({}, baseArgs || {}, {
        success: (data) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(data);
        },
        fail: (data, code) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          const msg =
            data && (data.message || data.msg)
              ? data.message || data.msg
              : code != null
                ? String(code)
                : "fail";
          reject(new Error(msg));
        },
        complete: () => {},
      });

      try {
        fn(args);
      } catch (e) {
        if (done) return;
        done = true;
        clearTimeout(t);
        reject(e);
      }
    });

  const applyAppInfo = (info) => {
    if (!info || typeof info !== "object") return;
    const name = pickFirstNonEmpty(info.name, info.appName);
    if (name) this.appName = name;

    const pkg = pickFirstNonEmpty(info.packageName, info.package, info.appId, info.id);
    if (pkg) {
      this.packageName = pkg;
      this.sandboxPath = `${QUICKAPP_ABS_BASE}${pkg}/`;
    }

    const source = info.source;
    if (source && typeof source === "object") {
      const st = pickFirstNonEmpty(source.type);
      if (st) this.appSourceText = mapAppSourceType(st);
    }

    const ver = pickFirstNonEmpty(info.versionName, info.version, info.appVersion);
    const build = pickFirstNonEmpty(
      info.versionCode != null ? String(info.versionCode) : "",
      info.buildNumber != null ? String(info.buildNumber) : ""
    );
    if (ver) this.appVersion = ver;
    if (build) this.buildNumber = build;
  };

  const applyDeviceInfo = (info) => {
    if (!info || typeof info !== "object") return;

    // https://iot.mi.com/vela/quickapp/zh/features/basic/device.html
    const model = pickFirstNonEmpty(info.model);
    const brand = pickFirstNonEmpty(info.brand);
    const manufacturer = pickFirstNonEmpty(info.manufacturer);
    const product = pickFirstNonEmpty(info.product);
    if (model) this.model = model;

    const dn = pickFirstNonEmpty(brand, manufacturer, product);
    if (dn) this.deviceName = dn;

    const osType = pickFirstNonEmpty(info.osType);
    const osName = pickFirstNonEmpty(info.osVersionName);
    const platName = pickFirstNonEmpty(info.platformVersionName);
    if (osType || osName) this.osVersion = pickFirstNonEmpty(`${osType} ${osName}`.trim(), osName, osType);
    if (platName) this.velaVersion = platName;

    const devId = pickFirstNonEmpty(info.deviceId);
    if (devId) this.deviceId = devId;

    const serial = pickFirstNonEmpty(info.serial);
    if (serial) this.serial = serial;

    const lang = pickFirstNonEmpty(info.language);
    const region = pickFirstNonEmpty(info.region);
    if (lang) this.language = lang;
    if (region) this.region = region;

    const sw = typeof info.screenWidth === "number" ? info.screenWidth : parseInt(info.screenWidth, 10);
    const sh = typeof info.screenHeight === "number" ? info.screenHeight : parseInt(info.screenHeight, 10);
    const shape = pickFirstNonEmpty(info.screenShape);
    if (isFinite(sw) && isFinite(sh) && sw > 0 && sh > 0) {
      this.screenText = shape ? `${sw}×${sh} (${shape})` : `${sw}×${sh}`;
    } else if (shape) {
      this.screenText = shape;
    }

    // 部分设备不会在 getInfo 里带存储字段；存储用 getTotalStorage/getAvailableStorage 单独拿
    const total = typeof info.totalStorage === "number" ? info.totalStorage : parseFloat(info.totalStorage);
    const avail = typeof info.availableStorage === "number" ? info.availableStorage : parseFloat(info.availableStorage);
    if (isFinite(total) && total > 0) {
      this.storageTotal = formatBytes(total);
      if (isFinite(avail)) {
        const used = Math.max(0, total - avail);
        this.storageUsed = formatBytes(used);
        this.storagePercent = clamp(Math.round((used / total) * 100), 0, 100);
      }
    }
  };

  // device.getInfo：兼容同步/异步两种实现（避免“双调用”造成 UI 二次跳动）
  try {
    if (device && typeof device.getInfo === "function") {
      let got = false;
      try {
        const maybe = device.getInfo();
        if (maybe && typeof maybe === "object") {
          applyDeviceInfo(maybe);
          got = true;
        }
      } catch (_) {}

      if (!got) {
        try {
          const info = await callSuccess(device.getInfo.bind(device), {}, 1200);
          if (info && typeof info === "object") applyDeviceInfo(info);
        } catch (_) {}
      }
    }
  } catch (_) {}

  // app.getInfo：兼容同步/异步两种实现（避免“双调用”造成 UI 二次跳动）
  try {
    if (app && typeof app.getInfo === "function") {
      let got = false;
      try {
        const maybe = app.getInfo();
        if (maybe && typeof maybe === "object") {
          applyAppInfo(maybe);
          got = true;
        }
      } catch (_) {}

      if (!got) {
        try {
          const info = await callSuccess(app.getInfo.bind(app), {}, 1200);
          if (info && typeof info === "object") applyAppInfo(info);
        } catch (_) {}
      }
    }
  } catch (_) {}

  // 存储：按文档使用 getTotalStorage/getAvailableStorage
  try {
    let total = NaN;
    let avail = NaN;

    if (device && typeof device.getTotalStorage === "function") {
      try {
        const r = await callSuccess(device.getTotalStorage.bind(device), {}, 1500);
        total = r && typeof r.totalStorage === "number" ? r.totalStorage : parseFloat(r && r.totalStorage);
      } catch (_) {}
    }

    if (device && typeof device.getAvailableStorage === "function") {
      try {
        const r2 = await callSuccess(device.getAvailableStorage.bind(device), {}, 1500);
        avail = r2 && typeof r2.availableStorage === "number" ? r2.availableStorage : parseFloat(r2 && r2.availableStorage);
      } catch (_) {}
    }

    if (isFinite(total) && total > 0) {
      this.storageTotal = formatBytes(total);
      if (isFinite(avail)) {
        const used = Math.max(0, total - avail);
        this.storageUsed = formatBytes(used);
        this.storagePercent = clamp(Math.round((used / total) * 100), 0, 100);
      }
    }
  } catch (_) {}

  // 若拿不到包名，兜底用 suIpc（可能被别处维护）
  try {
    const maybePkg = pickFirstNonEmpty(this.packageName);
    if (!maybePkg && suIpc && typeof suIpc.getPackageName === "function") {
      const p = suIpc.getPackageName();
      if (p) {
        this.packageName = p;
        this.sandboxPath = `${QUICKAPP_ABS_BASE}${p}/`;
      }
    }
  } catch (_) {}

  // configuration.getLocale()
  try {
    if (configuration && typeof configuration.getLocale === "function") {
      let loc;
      try {
        loc = configuration.getLocale();
      } catch (_) {
        loc = null;
      }
      if (!loc) {
        try {
          loc = await callSuccess(configuration.getLocale.bind(configuration), {}, 1200);
        } catch (_) {
          loc = null;
        }
      }
      if (loc && typeof loc === "object") {
        const lang = loc.language != null ? String(loc.language) : "";
        const cr = loc.countryOrRegion != null ? String(loc.countryOrRegion) : "";
        const t = [lang, cr].filter(Boolean).join("-");
        if (t) this.localeText = t;
      }
    }
  } catch (_) {}

  // network.getType()
  try {
    if (network && typeof network.getType === "function") {
      const r = await callSuccess(network.getType.bind(network), {}, 1200);
      const type = r && r.type;
      this.networkTypeText = mapNetworkType(type);
      this.networkDetailText = "";
    }
  } catch (_) {
    this.networkTypeText = "—";
    this.networkDetailText = "";
  }

  // brightness.getValue() / getMode()
  try {
    if (brightness && typeof brightness.getValue === "function") {
      const r = await callSuccess(brightness.getValue.bind(brightness), {}, 1200);
      const value = r && r.value;
      this.brightnessPercent = toPercent255(value);
      this.brightnessText = `${this.brightnessPercent}%`;
    }
    if (brightness && typeof brightness.getMode === "function") {
      const r2 = await callSuccess(brightness.getMode.bind(brightness), {}, 1200);
      const mode = r2 && r2.mode;
      const modeText = mapBrightnessMode(mode);
      this.brightnessText = this.brightnessText ? `${this.brightnessText}（${modeText}）` : modeText;
    }
  } catch (_) {}

  // battery.getStatus()
  try {
    if (battery && typeof battery.getStatus === "function") {
      const r = await callSuccess(battery.getStatus.bind(battery), {}, 1500);
      const pct = toPercent01(r && r.level);
      const charging = !!(r && r.charging);
      this.batteryPercent = pct;
      this.batteryText = charging ? `${pct}%（充电中）` : `${pct}%`;
    }
  } catch (_) {}

  // volume.getMediaValue()
  try {
    if (volume && typeof volume.getMediaValue === "function") {
      const r = await callSuccess(volume.getMediaValue.bind(volume), {}, 1200);
      const pct = toPercent01(r && r.value);
      this.volumePercent = pct;
      this.volumeText = `${pct}%`;
    }
  } catch (_) {}

  // vibrator.getSystemDefaultMode()
  try {
    if (vibrator && typeof vibrator.getSystemDefaultMode === "function") {
      const mode = vibrator.getSystemDefaultMode();
      const m = mode == null ? "" : String(mode);
      this.vibratorModeText = m ? `模式 ${m}` : "—";
      this.vibratorModeSub = m ? "0/1/2" : "";
    }
  } catch (_) {
    this.vibratorModeText = "—";
    this.vibratorModeSub = "";
  }

  if (collectLocation) {
  // geolocation.getLocation()
  try {
    if (geolocation && typeof geolocation.getLocation === "function") {
      const r = await callSuccess(geolocation.getLocation.bind(geolocation), { timeout: 2500 }, 3000);
      const lat = r && isFinite(r.latitude) ? r.latitude : null;
      const lon = r && isFinite(r.longitude) ? r.longitude : null;
      const acc = r && isFinite(r.accuracy) ? r.accuracy : null;
      if (lat != null && lon != null) {
        const a = acc != null ? ` ±${Math.round(acc)}m` : "";
        this.locationText = `${lat.toFixed(5)}, ${lon.toFixed(5)}${a}`;
      }
    }
  } catch (_) {
    if (!this.locationText) this.locationText = "不可用";
  }
  } else if (!this.locationText) {
    this.locationText = "点击刷新获取";
  }

  if (collectSensors) {
  // sensor: subscribe once (compass + accelerometer)
  try {
    if (sensor && typeof sensor.subscribeCompass === "function" && typeof sensor.unsubscribeCompass === "function") {
      const compass = await new Promise((resolve) => {
        let done = false;
        const t = setTimeout(() => {
          if (done) return;
          done = true;
          try {
            sensor.unsubscribeCompass();
          } catch (_) {}
          resolve(null);
        }, 1200);

        try {
          sensor.subscribeCompass({
            callback: (data) => {
              if (done) return;
              done = true;
              clearTimeout(t);
              try {
                sensor.unsubscribeCompass();
              } catch (_) {}
              resolve(data);
            },
            fail: () => {
              if (done) return;
              done = true;
              clearTimeout(t);
              try {
                sensor.unsubscribeCompass();
              } catch (_) {}
              resolve(null);
            },
          });
        } catch (_) {
          if (done) return;
          done = true;
          clearTimeout(t);
          try {
            sensor.unsubscribeCompass();
          } catch (_) {}
          resolve(null);
        }
      });

      if (compass && compass.direction != null) {
        const deg = radToDeg(compass.direction);
        if (deg != null) {
          const dir = compassFromDeg(deg);
          this.compassText = dir
            ? `${dir} ${Math.round(((deg % 360) + 360) % 360)}°`
            : `${Math.round(deg)}°`;
        }
      }
    }
  } catch (_) {}

  try {
    if (
      sensor
      && typeof sensor.subscribeAccelerometer === "function"
      && typeof sensor.unsubscribeAccelerometer === "function"
    ) {
      const acc = await new Promise((resolve) => {
        let done = false;
        const t = setTimeout(() => {
          if (done) return;
          done = true;
          try {
            sensor.unsubscribeAccelerometer();
          } catch (_) {}
          resolve(null);
        }, 1200);

        try {
          sensor.subscribeAccelerometer({
            interval: "normal",
            callback: (data) => {
              if (done) return;
              done = true;
              clearTimeout(t);
              try {
                sensor.unsubscribeAccelerometer();
              } catch (_) {}
              resolve(data);
            },
            fail: () => {
              if (done) return;
              done = true;
              clearTimeout(t);
              try {
                sensor.unsubscribeAccelerometer();
              } catch (_) {}
              resolve(null);
            },
          });
        } catch (_) {
          if (done) return;
          done = true;
          clearTimeout(t);
          try {
            sensor.unsubscribeAccelerometer();
          } catch (_) {}
          resolve(null);
        }
      });

      if (acc && (acc.x != null || acc.y != null || acc.z != null)) {
        const x = acc.x != null && isFinite(acc.x) ? acc.x.toFixed(2) : "—";
        const y = acc.y != null && isFinite(acc.y) ? acc.y.toFixed(2) : "—";
        const z = acc.z != null && isFinite(acc.z) ? acc.z.toFixed(2) : "—";
        this.accelText = `x:${x} y:${y} z:${z}`;
      }
    }
  } catch (_) {}
  } else {
    if (!this.compassText) this.compassText = "点击刷新获取";
    if (!this.accelText) this.accelText = "点击刷新获取";
  }

  this.isRefreshingBasic = false;
  setTimeout(() => {
    try {
      this.restoreScroll(keepY);
    } catch (_) {}
  }, 0);
}
