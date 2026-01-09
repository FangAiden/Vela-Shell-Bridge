import storage from "@system.storage";

function storageGetRaw(key, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      resolve(null);
    }, timeoutMs || 800);

    try {
      storage.get({
        key,
        success: (data) => {
          if (done) return;
          done = true;
          clearTimeout(t);
          if (data && data.value != null) resolve(data.value);
          else resolve(data);
        },
        fail: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(null);
        },
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve(null);
    }
  });
}

function storageSetRaw(key, value, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const t = setTimeout(() => {
      if (done) return;
      done = true;
      resolve(false);
    }, timeoutMs || 800);

    try {
      storage.set({
        key,
        value,
        success: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(true);
        },
        fail: () => {
          if (done) return;
          done = true;
          clearTimeout(t);
          resolve(false);
        },
      });
    } catch (_) {
      if (done) return;
      done = true;
      clearTimeout(t);
      resolve(false);
    }
  });
}

export async function getJson(key) {
  const raw = await storageGetRaw(key);
  if (!raw || typeof raw !== "string") return null;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

export async function setJson(key, obj) {
  try {
    return await storageSetRaw(key, JSON.stringify(obj));
  } catch (_) {
    return false;
  }
}

