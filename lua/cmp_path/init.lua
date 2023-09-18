local cmp = require("cmp")

local source = {}

local constants = {
  max_lines = 20,
}

---@class cmp_path.Option
---@field public trailing_slash boolean
---@field public label_trailing_slash boolean
---@field public get_cwd fun(): string
-- lua/option\ with\ spaces/some
---@type cmp_path.Option
local defaults = {
  trailing_slash = false,
  label_trailing_slash = true,
  filename_regex = [[[^%s{}%[%]"']+$]],
  get_cwd = function(params)
    return vim.fn.expand(("#%d:p:h"):format(params.context.bufnr))
  end,
}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.complete = function(self, params, callback)
  local option = self:_validate_option(params)

  local dirname = self:_dirname(params, option)
  if not dirname then
    return callback()
  end

  local include_hidden = string.sub(
    params.context.cursor_before_line,
    params.offset,
    params.offset
  ) == "."
  self:_candidates(dirname, include_hidden, option, function(err, candidates)
    if err then
      return callback()
    end
    callback(candidates)
  end)
end

source.resolve = function(self, completion_item, callback)
  local data = completion_item.data
  if data.stat and data.stat.type == "file" then
    local ok, documentation = pcall(function()
      return self:_get_documentation(data.path, constants.max_lines)
    end)
    if ok then
      completion_item.documentation = documentation
    end
  end
  callback(completion_item)
end

source._dirname = function(self, params, option)
  local filename =
    params.context.cursor_before_line:match(option.filename_regex)
  if not filename or #filename == 0 then
    return
  end

  if filename:sub(1, 1) == "/" then
    filename = vim.fs.normalize(filename)
  else
    filename = vim.fs.joinpath(option.get_cwd(params), filename)
  end

  return vim.fs.dirname(filename)
end

source._candidates = function(_, dirname, include_hidden, option, callback)
  local items = {}

  local function create_item(name, fs_type)
    if not (include_hidden or string.sub(name, 1, 1) ~= ".") then
      return
    end

    local path = dirname .. "/" .. name
    local stat = vim.loop.fs_stat(path)
    local lstat = nil
    if stat then
      fs_type = stat.type
    elseif fs_type == "link" then
      -- Broken symlink
      lstat = vim.loop.fs_lstat(dirname)
      if not lstat then
        return
      end
    else
      return
    end

    local item = {
      label = name,
      filterText = name,
      insertText = name,
      kind = cmp.lsp.CompletionItemKind.File,
      data = {
        path = path,
        type = fs_type,
        stat = stat,
        lstat = lstat,
      },
    }
    if fs_type == "directory" then
      item.kind = cmp.lsp.CompletionItemKind.Folder
      if option.label_trailing_slash then
        item.label = name .. "/"
      else
        item.label = name
      end
      item.insertText = name .. "/"
      if not option.trailing_slash then
        item.word = name
      end
    end
    table.insert(items, item)
  end

  for name, fs_type in vim.fs.dir(dirname) do
    create_item(name, fs_type)
  end

  callback(nil, items)
end

source._is_slash_comment = function(_)
  local commentstring = vim.bo.commentstring or ""
  local no_filetype = vim.bo.filetype == ""
  local is_slash_comment = false
  is_slash_comment = is_slash_comment or commentstring:match("/%*")
  is_slash_comment = is_slash_comment or commentstring:match("//")
  return is_slash_comment and not no_filetype
end

---@return cmp_path.Option
source._validate_option = function(_, params)
  local option = vim.tbl_deep_extend("keep", params.option, defaults)
  vim.validate({
    trailing_slash = { option.trailing_slash, "boolean" },
    label_trailing_slash = { option.label_trailing_slash, "boolean" },
    get_cwd = { option.get_cwd, "function" },
  })
  return option
end

source._get_documentation = function(_, filename, count)
  local binary = assert(io.open(filename, "rb"))
  local first_kb = binary:read(1024)
  if first_kb:find("\0") then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = "binary file" }
  end

  local contents = {}
  for content in first_kb:gmatch("[^\r\n]+") do
    table.insert(contents, content)
    if count ~= nil and #contents >= count then
      break
    end
  end

  local filetype = vim.filetype.match({ filename = filename })
  if not filetype then
    return {
      kind = cmp.lsp.MarkupKind.PlainText,
      value = table.concat(contents, "\n"),
    }
  end

  table.insert(contents, 1, "```" .. filetype)
  table.insert(contents, "```")
  return {
    kind = cmp.lsp.MarkupKind.Markdown,
    value = table.concat(contents, "\n"),
  }
end

return source
