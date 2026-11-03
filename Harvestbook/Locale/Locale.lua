local ADDON, ns = ...

-- Translation table. The key is the English text, so anything untranslated
-- (koKR, zhCN and zhTW have no file; they need fonts and a translator) shows
-- in English. Display text only: never store L[...] or use it as a key.
ns.L = setmetatable({}, {
  __index = function(_, key) return key end,
  __newindex = function(t, key, value) rawset(t, key, value == true and key or value) end,
})
