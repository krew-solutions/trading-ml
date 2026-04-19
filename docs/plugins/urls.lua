-- Normalize all URLs (href, src) so the rendered site works equally well
-- via an HTTP server AND from the local filesystem (file:// protocol).
--
-- Three transformations applied in order:
--
--   1. *.md links rewritten to clean URLs:
--        architecture/overview.md  ->  architecture/overview/
--        adr/README.md             ->  adr/
--
--   2. Directory-style URLs get an explicit /index.html so file://
--      browsing doesn't 404 on missing directory listings.
--
--   3. Absolute paths ("/foo/bar") are rewritten to filesystem-relative
--      paths based on the current page's depth below site root:
--        On _site/index.html:               /styles/main.css ->     styles/main.css
--        On _site/architecture/overview/:   /styles/main.css ->  ../../styles/main.css
--
-- External URLs (http://, mailto:), bare anchors (#x), and parent-escape
-- paths (../*) are left untouched.
--
-- NOTE on Lua dialect: soupault embeds lua-ml (Lua 2.5-flavoured), which has
-- no native boolean type. Use `1`/`nil` instead of `true`/`false`.

-- ---- 1. Compute the current page's depth below site root --------------------

src = Regex.replace(page_file, "^\\./", "")
src_dir = Sys.dirname(src)
src_basename = Sys.basename(src)
src_stem = Regex.replace(src_basename, "\\.md$", "")

if (src_dir == "") or (src_dir == ".") then
  num_dirs = 0
else
  slashes = Regex.find_all(src_dir, "/")
  if slashes and (size(slashes) > 0) then
    num_dirs = size(slashes) + 1
  else
    num_dirs = 1
  end
end

-- README.md is the section index (no slug-dir from clean_urls);
-- every other page gets an additional level from its slug directory.
if src_stem == "README" then
  depth = num_dirs
else
  depth = num_dirs + 1
end

prefix = ""
d = 1
while d <= depth do
  prefix = prefix .. "../"
  d = d + 1
end

-- ---- 2. Iterate over all (href|src) attributes ------------------------------

selectors = {"a[href]", "link[href]", "img[src]", "script[src]", "source[src]"}
attrs     = {"href",    "href",       "src",      "src",         "src"}
nspec = 5

s = 1
while s <= nspec do
  els  = HTML.select(page, selectors[s])
  attr = attrs[s]
  m = size(els)
  k = 1
  while k <= m do
    el  = els[k]
    val = HTML.get_attribute(el, attr)

    -- Decide whether to skip this URL
    skip = nil
    if not val then skip = 1 end
    if val == "" then skip = 1 end
    if (not skip) and Regex.match(val, "^[a-z]+://") then skip = 1 end
    if (not skip) and Regex.match(val, "^//")        then skip = 1 end
    if (not skip) and Regex.match(val, "^mailto:")   then skip = 1 end
    if (not skip) and Regex.match(val, "^#")         then skip = 1 end
    if (not skip) and Regex.match(val, "^\\?")       then skip = 1 end

    if not skip then
      -- Split off optional fragment
      fragment = ""
      if Regex.match(val, "#") then
        fmatch = Regex.find_all(val, "#.*$")
        if fmatch and (size(fmatch) > 0) then fragment = fmatch[1] end
        val = Regex.replace(val, "#.*$", "")
      end

      -- (a) Rewrite *.md to clean URL
      if Regex.match(val, "README\\.md$") then
        val = Regex.replace(val, "README\\.md$", "")
      end
      if Regex.match(val, "\\.md$") then
        val = Regex.replace(val, "\\.md$", "/")
      end

      -- (b) Strip leading slash, remember whether it was absolute
      absolute = nil
      if Regex.match(val, "^/") then
        absolute = 1
        val = Regex.replace(val, "^/", "")
      end

      -- (c) Append index.html for directory-style URLs
      if val == "" then
        val = "index.html"
      end
      if Regex.match(val, "/$") then
        val = val .. "index.html"
      end
      -- If the last path segment carries no extension, treat it as a directory
      if not Regex.match(val, "\\.[a-zA-Z0-9]+$") then
        if not Regex.match(val, "/$") then
          val = val .. "/index.html"
        end
      end

      -- (d) Relativize absolute URLs based on current page depth
      if absolute then
        if prefix == "" then
          val = "./" .. val
        else
          val = prefix .. val
        end
      end

      HTML.set_attribute(el, attr, val .. fragment)
    end

    k = k + 1
  end
  s = s + 1
end
