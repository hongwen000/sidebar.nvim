-- filepath: c:\Users\lixinrui\repo\sidebar.nvim\lua\sidebar-nvim\builtin\search.lua
local utils = require("sidebar-nvim.utils")
local Loclist = require("sidebar-nvim.components.loclist")
local config = require("sidebar-nvim.config")
local luv = vim.loop

-- 扩展默认配置
if not config.search then
    config.search = {
        icon = "🔍",
        case_sensitive = false,
        use_regex = true,
        whole_word = false,
        include_pattern = "",
        exclude_pattern = "",
        max_history = 10,          -- 搜索历史记录数量
        backup_files = true,       -- 替换前备份文件
        preview_context_lines = 3, -- 预览上下文行数
        max_results = 1000,        -- 最大结果数量限制
    }
end

-- 初始化位置列表
local loclist = Loclist:new({
    show_group_count = true,
    show_empty_groups = false,
    omit_single_group = false,
})

-- SearchState 类：管理搜索相关状态
local SearchState = {}

function SearchState:new()
    local state = {
        query = "",
        replace_text = "",
        include_pattern = config.search.include_pattern or "",
        exclude_pattern = config.search.exclude_pattern or "",
        case_sensitive = config.search.case_sensitive or false,
        use_regex = config.search.use_regex or true,
        whole_word = config.search.whole_word or false,
        searching = false,
        results = {},
        input_mode = "search",
        history = {},
        preview_buf = nil,
        preview_win = nil,
        search_handle = nil,
        timer = nil,
    }
    
    setmetatable(state, self)
    self.__index = self
    return state
end

function SearchState:set_query(query)
    if query == "" or query == self.query then return end
    
    self.query = query
    self:add_to_history(query)
end

function SearchState:add_to_history(query)
    if query == "" then return end
    
    -- 避免重复
    for i, item in ipairs(self.history) do
        if item == query then
            table.remove(self.history, i)
            break
        end
    end
    
    -- 添加到历史记录开头
    table.insert(self.history, 1, query)
    
    -- 限制历史记录数量
    if #self.history > config.search.max_history then
        table.remove(self.history)
    end
end

function SearchState:toggle_setting(setting)
    if self[setting] ~= nil and type(self[setting]) == "boolean" then
        self[setting] = not self[setting]
        return true
    end
    return false
end

function SearchState:cancel_search()
    if self.searching and self.search_handle and not self.search_handle:is_closing() then
        self.search_handle:kill(15)  -- SIGTERM
        self.searching = false
        
        if self.timer then
            self.timer:stop()
            self.timer:close()
            self.timer = nil
        end
        
        vim.schedule(function()
            utils.echo_warning("搜索已取消")
        end)
        return true
    end
    return false
end

function SearchState:clear_preview()
    if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
        vim.api.nvim_win_close(self.preview_win, true)
        self.preview_win = nil
    end
    
    if self.preview_buf and vim.api.nvim_buf_is_valid(self.preview_buf) then
        vim.api.nvim_buf_delete(self.preview_buf, { force = true })
        self.preview_buf = nil
    end
end

-- 创建搜索状态实例
local state = SearchState:new()

-- UI图标定义
local icons = {
    case_sensitive = { on = "Aa", off = "aa" },
    word = { on = "\\b", off = "ab" },
    regex = { on = ".*", off = "\\*" },
    check = { on = "■", off = "□" },
    search = "🔍",
    replace = "🔄",
    include = "📂",
    exclude = "🚫",
    history = "📜",
    preview = "👁️",
    close = "✖",
}

-- 文件备份函数
local function backup_file(filepath)
    if not config.search.backup_files then
        return true
    end
    
    local backup_path = filepath .. ".bak"
    local cmd
    
    if vim.fn.has("win32") == 1 then
        cmd = string.format('copy "%s" "%s"', filepath:gsub("/", "\\"), backup_path:gsub("/", "\\"))
    else
        cmd = string.format('cp "%s" "%s"', filepath, backup_path)
    end
    
    local result = vim.fn.system(cmd)
    
    if vim.v.shell_error ~= 0 then
        vim.schedule(function()
            utils.echo_warning("备份文件失败 " .. filepath .. ": " .. result)
        end)
        return false
    end
    
    return true
end

-- 高亮匹配结果
local function highlight_match(text, pattern, is_regex, case_sensitive)
    if not is_regex then
        pattern = vim.pesc(pattern)
    end
    
    local flags = case_sensitive and "" or "i"
    
    local ok, start_pos, end_pos = pcall(function()
        return text:find(pattern, 1, false, flags)
    end)
    
    if not ok or not start_pos then
        return nil
    end
    
    return start_pos, end_pos
end

-- 处理搜索结果并更新位置列表
local function process_search_results(results)
    local items = {}
    loclist:clear()
    
    if not results or #results == 0 then
        return
    end
    
    -- 按文件分组结果
    local files = {}
    for _, match in ipairs(results) do
        local filepath = match.filepath
        if not files[filepath] then
            files[filepath] = {}
            loclist:add_group(filepath)
        end
        table.insert(files[filepath], match)
    end
    
    -- 添加项目到位置列表
    for filepath, matches in pairs(files) do
        for _, match in ipairs(matches) do
            local line_text = match.line_text:gsub("\t", "    ") -- 替换制表符为空格
            local start_pos, end_pos
            
            -- 尝试在文本中高亮匹配项
            if state.query ~= "" then
                start_pos, end_pos = highlight_match(
                    line_text, 
                    state.query, 
                    state.use_regex, 
                    state.case_sensitive
                )
            end
            
            if start_pos and end_pos then
                -- 添加带高亮的匹配项
                table.insert(items, {
                    group = match.filepath,
                    left = {
                        { text = match.line_num .. ": ", hl = "SidebarNvimLineNr" },
                        { text = line_text:sub(1, start_pos - 1) },
                        { text = line_text:sub(start_pos, end_pos), hl = "SidebarNvimSearchMatch" },
                        { text = line_text:sub(end_pos + 1) },
                    },
                    filepath = match.filepath,
                    line_num = match.line_num,
                    col = match.col,
                    context = match.context or {},
                })
            else
                -- 回退到普通显示
                table.insert(items, {
                    group = match.filepath,
                    left = {
                        { text = match.line_num .. ": ", hl = "SidebarNvimLineNr" },
                        { text = line_text },
                    },
                    filepath = match.filepath,
                    line_num = match.line_num,
                    col = match.col,
                    context = match.context or {},
                })
            end
        end
    end
    
    loclist:set_items(items, { remove_groups = false })
end

-- 执行搜索
local function execute_search()
    if state.query == "" or state.searching then
        return
    end
    
    -- 取消正在进行的搜索
    state:cancel_search()
    
    state.searching = true
    local results = {}
    local stdout = luv.new_pipe(false)
    local stderr = luv.new_pipe(false)
    
    local cmd = "rg"
    local args = {}
    
    if vim.fn.executable("rg") == 1 then
        cmd = "rg"
        args = {
            "--line-number",
            "--column",
            "--no-heading",
            "--color", "never",
            "--max-count", tostring(config.search.max_results),
        }
        
        if not state.case_sensitive then
            table.insert(args, "--ignore-case")
        end
        
        if state.whole_word then
            table.insert(args, "--word-regexp")
        end
        
        if not state.use_regex then
            table.insert(args, "--fixed-strings")
        end
        
        if state.include_pattern ~= "" then
            for _, pattern in ipairs(vim.split(state.include_pattern, ",")) do
                pattern = vim.trim(pattern)
                if pattern ~= "" then
                    table.insert(args, "--glob")
                    table.insert(args, pattern)
                end
            end
        end
        
        if state.exclude_pattern ~= "" then
            for _, pattern in ipairs(vim.split(state.exclude_pattern, ",")) do
                pattern = vim.trim(pattern)
                if pattern ~= "" then
                    table.insert(args, "--glob")
                    table.insert(args, "!" .. pattern)
                end
            end
        end
        
        table.insert(args, "--context")
        table.insert(args, tostring(config.search.preview_context_lines))
        
        table.insert(args, state.query)
    else
        -- 如果没有ripgrep则回退到grep
        cmd = "grep"
        args = {
            "-n", -- 行号
            "-H", -- 打印文件名
            "--color=never",
        }
        
        if not state.case_sensitive then
            table.insert(args, "-i")
        end
        
        if state.whole_word then
            table.insert(args, "-w")
        end
        
        if not state.use_regex then
            table.insert(args, "-F")
        end
        
        table.insert(args, state.query)
        
        if state.include_pattern ~= "" then
            table.insert(args, state.include_pattern)
        else
            table.insert(args, "*")
        end
    end
    
    -- 创建进度定时器
    state.timer = luv.new_timer()
    state.timer:start(100, 100, vim.schedule_wrap(function()
        if state.searching then
            utils.echo_info(string.format("正在搜索... 已找到 %d 个结果", #results))
        end
    end))
    
    state.search_handle = luv.spawn(cmd, {
        args = args,
        stdio = { nil, stdout, stderr },
        cwd = luv.cwd(),
    }, function()
        state.searching = false
        
        if state.timer then
            state.timer:stop()
            state.timer:close()
            state.timer = nil
        end
        
        vim.schedule(function()
            process_search_results(results)
            utils.echo_info(string.format("在 %d 个文件中找到 %d 个匹配项", 
                vim.tbl_count(loclist:get_groups()),
                #results
            ))
        end)
        
        luv.read_stop(stdout)
        luv.read_stop(stderr)
        stdout:close()
        stderr:close()
        state.search_handle:close()
    end)
    
    -- 处理带上下文的ripgrep输出
    local current_file = nil
    local current_matches = {}
    local context_lines = {}
    
    luv.read_start(stdout, function(err, data)
        if data == nil then return end
        
        for _, line in ipairs(vim.split(data, "\n")) do
            if line ~= "" then
                -- 解析ripgrep输出格式
                local file_sep = line:match("^(.+)%-%-$")
                
                if file_sep then
                    -- 文件分隔符，保存之前的上下文并重置
                    if current_file and #current_matches > 0 then
                        for _, match in ipairs(current_matches) do
                            match.context = context_lines
                        end
                        vim.list_extend(results, current_matches)
                    end
                    
                    current_file = nil
                    current_matches = {}
                    context_lines = {}
                elseif line:match("^%d+%[") then
                    -- 上下文行（非匹配行）
                    local line_num, content = line:match("^(%d+)%[.-%](.*)$")
                    if line_num and content then
                        table.insert(context_lines, {
                            line_num = tonumber(line_num),
                            content = content,
                            is_match = false
                        })
                    end
                elseif line:match("^%d+:") then
                    -- 匹配行
                    local filepath, line_num, col, line_text = line:match("^(.+):(%d+):(%d+):(.*)$")
                    
                    if filepath and line_num and col and line_text then
                        if current_file ~= filepath then
                            -- 发现新文件
                            if current_file and #current_matches > 0 then
                                for _, match in ipairs(current_matches) do
                                    match.context = context_lines
                                end
                                vim.list_extend(results, current_matches)
                            end
                            
                            current_file = filepath
                            current_matches = {}
                            context_lines = {}
                        end
                        
                        -- 添加到上下文行
                        table.insert(context_lines, {
                            line_num = tonumber(line_num),
                            content = line_text,
                            is_match = true
                        })
                        
                        -- 添加到匹配项
                        table.insert(current_matches, {
                            filepath = filepath,
                            line_num = tonumber(line_num),
                            col = tonumber(col),
                            line_text = line_text,
                        })
                    end
                end
            end
        end
        
        if err ~= nil then
            vim.schedule(function()
                utils.echo_warning(err)
            end)
        end
    end)
    
    luv.read_start(stderr, function(err, data)
        if data == nil then return end
        
        if err ~= nil or data:match("error") then
            vim.schedule(function()
                utils.echo_warning("搜索错误: " .. (data or err))
            end)
        end
    end)
    
    -- 添加到历史记录
    state:add_to_history(state.query)
end

-- 执行替换操作
local function execute_replace()
    if state.query == "" or state.replace_text == "" then
        utils.echo_warning("搜索关键词和替换文本不能为空")
        return
    end
    
    local locations = loclist:get_all_locations()
    if #locations == 0 then
        utils.echo_warning("没有搜索结果可替换")
        return
    end
    
    -- 收集唯一文件
    local files_to_replace = {}
    for _, location in ipairs(locations) do
        files_to_replace[location.filepath] = true
    end
    
    -- 替换前确认
    local file_count = vim.tbl_count(files_to_replace)
    local confirm = vim.fn.confirm(
        string.format("将 '%s' 替换为 '%s' 在 %d 个文件中?", 
            state.query, state.replace_text, file_count),
        "&确认\n&取消\n&预览", 
        2
    )
    
    if confirm ~= 1 then
        if confirm == 3 then
            -- 显示更改预览
            preview_replace(files_to_replace)
        end
        return
    end
    
    -- 先备份文件
    local all_backed_up = true
    for filepath in pairs(files_to_replace) do
        if not backup_file(filepath) then
            all_backed_up = false
            break
        end
    end
    
    if not all_backed_up then
        local continue = vim.fn.confirm(
            "某些文件无法备份。是否继续?",
            "&继续\n&取消",
            2
        )
        if continue ~= 1 then
            return
        end
    end
    
    -- 执行替换
    local success_count = 0
    local failure_count = 0
    
    for filepath in pairs(files_to_replace) do
        local sed_cmd = "sed"
        local sed_args = {}
        
        if vim.fn.has("win32") == 1 then
            -- Windows使用PowerShell执行替换
            sed_cmd = "powershell"
            local search_pattern = state.query
            if not state.use_regex then
                -- 如果不使用正则，转义特殊字符
                search_pattern = search_pattern:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "\\%1")
            end
            
            sed_args = {
                "-Command",
                "(Get-Content '" .. filepath .. "') | ForEach-Object { $_ -replace '" .. 
                search_pattern .. "', '" .. state.replace_text .. "' } | Set-Content '" .. filepath .. "'"
            }
        else
            -- Unix系统
            local flags = "g"  -- 全局替换
            if not state.case_sensitive then
                flags = flags .. "i"  -- 忽略大小写
            end
            
            sed_args = {
                "-i",
                "s/" .. state.query .. "/" .. state.replace_text .. "/" .. flags,
                filepath
            }
        end
        
        local result = vim.fn.system(sed_cmd .. " " .. table.concat(sed_args, " "))
        if vim.v.shell_error ~= 0 then
            utils.echo_warning("替换文件时出错 " .. filepath .. ": " .. result)
            failure_count = failure_count + 1
        else
            success_count = success_count + 1
        end
    end
    
    -- 报告结果
    utils.echo_info(string.format(
        "已将 '%s' 替换为 '%s' 在 %d/%d 个文件中%s", 
        state.query, 
        state.replace_text, 
        success_count,
        file_count,
        failure_count > 0 and " (" .. failure_count .. " 个失败)" or ""
    ))
    
    -- 重新运行搜索更新结果
    execute_search()
end

-- 替换预览
local function preview_replace(files_to_replace)
    -- 创建预览缓冲区
    if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
        state.preview_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(state.preview_buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(state.preview_buf, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(state.preview_buf, "swapfile", false)
        vim.api.nvim_buf_set_option(state.preview_buf, "filetype", "diff")
    end
    
    -- 生成差异预览
    local preview_lines = {}
    table.insert(preview_lines, "替换预览:")
    table.insert(preview_lines, "搜索: " .. state.query)
    table.insert(preview_lines, "替换: " .. state.replace_text)
    table.insert(preview_lines, string.rep("-", 40))
    
    for filepath in pairs(files_to_replace) do
        local file_content = {}
        
        -- 读取文件
        local file = io.open(filepath, "r")
        if file then
            for line in file:lines() do
                table.insert(file_content, line)
            end
            file:close()
            
            -- 预览更改
            table.insert(preview_lines, "文件: " .. filepath)
            table.insert(preview_lines, "")
            
            for i, line in ipairs(file_content) do
                local start_pos, end_pos
                
                if state.use_regex then
                    -- 尝试使用正则表达式查找匹配项
                    local ok, s, e = pcall(function()
                        return line:find(state.query)
                    end)
                    
                    if ok and s then
                        start_pos, end_pos = s, e
                    end
                else
                    -- 普通文本搜索
                    start_pos, end_pos = line:find(state.query, 1, true)
                end
                
                if start_pos then
                    local new_line = line:sub(1, start_pos - 1) .. 
                                    state.replace_text .. 
                                    line:sub(end_pos + 1)
                    
                    table.insert(preview_lines, "- " .. line)
                    table.insert(preview_lines, "+ " .. new_line)
                    table.insert(preview_lines, "")
                end
            end
            
            table.insert(preview_lines, string.rep("-", 40))
        end
    end
    
    -- 设置缓冲区内容
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, preview_lines)
    
    -- 创建窗口
    if not state.preview_win or not vim.api.nvim_win_is_valid(state.preview_win) then
        vim.cmd("botright split")
        state.preview_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)
        vim.api.nvim_win_set_height(state.preview_win, 15)
        
        -- 添加关闭预览的映射
        vim.api.nvim_buf_set_keymap(
            state.preview_buf, 
            "n", 
            "q", 
            "<cmd>lua require('sidebar-nvim.builtin.search').close_preview()<CR>", 
            { noremap = true, silent = true }
        )
    end
end

-- 浏览并选择搜索历史
local function browse_history()
    if #state.history == 0 then
        utils.echo_warning("没有搜索历史")
        return
    end
    
    vim.ui.select(state.history, {
        prompt = "从搜索历史中选择:",
        format_item = function(item) return item end,
    }, function(choice)
        if not choice then return end
        
        state.query = choice
        execute_search()
    end)
end

-- 显示文件预览
local function show_preview(location)
    if not location or not location.filepath then
        return
    end
    
    -- 清除现有预览
    state:clear_preview()
    
    -- 创建预览缓冲区
    state.preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.preview_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(state.preview_buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.preview_buf, "swapfile", false)
    vim.api.nvim_buf_set_name(state.preview_buf, "预览: " .. location.filepath)
    
    -- 读取文件内容
    local file_content = {}
    local file = io.open(location.filepath, "r")
    if file then
        for line in file:lines() do
            table.insert(file_content, line)
        end
        file:close()
        
        -- 设置缓冲区内容
        vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, file_content)
        
        -- 根据文件类型设置语法高亮
        local ft = vim.filetype.match({ filename = location.filepath })
        if ft then
            vim.api.nvim_buf_set_option(state.preview_buf, "filetype", ft)
        end
        
        -- 创建预览窗口
        vim.cmd("botright split")
        state.preview_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)
        vim.api.nvim_win_set_height(state.preview_win, 10)
        
        -- 跳转到匹配行
        vim.api.nvim_win_set_cursor(state.preview_win, {location.line_num, location.col - 1})
        
        -- 将视图居中于匹配行
        vim.cmd("normal! zz")
        
        -- 高亮搜索词
        if state.query ~= "" then
            vim.fn.matchadd("Search", state.use_regex and state.query or vim.fn.escape(state.query, "\\.*^$[]"))
        end
        
        -- 添加关闭预览的映射
        vim.api.nvim_buf_set_keymap(
            state.preview_buf, 
            "n", 
            "q", 
            "<cmd>lua require('sidebar-nvim.builtin.search').close_preview()<CR>", 
            { noremap = true, silent = true }
        )
    else
        utils.echo_warning("无法打开文件: " .. location.filepath)
    end
end

-- 处理搜索字段输入
local function handle_input(field)
    local prompt_prefix = ""
    local current_value = ""
    
    if field == "search" then
        prompt_prefix = "搜索: "
        current_value = state.query
    elseif field == "replace" then
        prompt_prefix = "替换: "
        current_value = state.replace_text
    elseif field == "include" then
        prompt_prefix = "包含模式: "
        current_value = state.include_pattern
    elseif field == "exclude" then
        prompt_prefix = "排除模式: "
        current_value = state.exclude_pattern
    end
    
    -- 切换到正常窗口进行输入
    vim.cmd("wincmd p")
    
    local completion = ""
    if field == "include" or field == "exclude" then
        completion = "file"
    end
    
    local new_value = vim.fn.input({
        prompt = prompt_prefix,
        default = current_value,
        completion = completion,
    })
    
    -- 切回侧边栏
    vim.cmd("wincmd p")
    
    if field == "search" then
        if new_value ~= state.query then
            state.query = new_value
            if state.query ~= "" then
                execute_search()
            end
        end
    elseif field == "replace" then
        state.replace_text = new_value
    elseif field == "include" then
        state.include_pattern = new_value
    elseif field == "exclude" then
        state.exclude_pattern = new_value
    end
    
    state.input_mode = field
end

-- 绘制搜索表单
local function draw_search_form(ctx)
    local lines = {}
    local hl = {}
    local width = ctx.width - 2
    
    -- 搜索输入字段
    local search_prefix = " " .. icons.search .. " 搜索 : "
    local search_display = state.query
    if search_display == "" then
        search_display = "__________________"
    end
    local search_line = search_prefix .. search_display
    
    table.insert(lines, search_line)
    
    if state.input_mode == "search" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #search_prefix, #search_prefix + #search_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #search_prefix, #search_prefix + #search_display })
    end
    
    -- 添加大小写、正则、全词切换按钮
    local toggle_offset = width - 12
    -- 大小写敏感
    local case_icon = state.case_sensitive and icons.case_sensitive.on or icons.case_sensitive.off
    table.insert(hl, { "SidebarNvimSearchToggle", #lines, toggle_offset, toggle_offset + 2 })
    lines[#lines] = lines[#lines] .. string.rep(" ", toggle_offset - #lines[#lines]) .. case_icon
    
    -- 词边界
    local word_icon = state.whole_word and icons.word.on or icons.word.off
    table.insert(hl, { "SidebarNvimSearchToggle", #lines, toggle_offset + 3, toggle_offset + 5 })
    lines[#lines] = lines[#lines] .. " " .. word_icon
    
    -- 正则表达式切换
    local regex_icon = state.use_regex and icons.regex.on or icons.regex.off
    table.insert(hl, { "SidebarNvimSearchToggle", #lines, toggle_offset + 6, toggle_offset + 8 })
    lines[#lines] = lines[#lines] .. " " .. regex_icon
    
    -- 历史按钮
    table.insert(hl, { "SidebarNvimSearchButton", #lines, toggle_offset + 9, toggle_offset + 10 })
    lines[#lines] = lines[#lines] .. " " .. icons.history
    
    -- 替换输入字段
    local replace_prefix = " " .. icons.replace .. " 替换 : "
    local replace_display = state.replace_text
    if replace_display == "" then
        replace_display = "__________________"
    end
    local replace_line = replace_prefix .. replace_display
    
    table.insert(lines, replace_line)
    
    if state.input_mode == "replace" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #replace_prefix, #replace_prefix + #replace_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #replace_prefix, #replace_prefix + #replace_display })
    end
    
    -- 替换按钮
    table.insert(hl, { "SidebarNvimSearchButton", #lines, width - 2, width })
    lines[#lines] = lines[#lines] .. string.rep(" ", width - #lines[#lines] - 2) .. " R"
    
    -- 包含模式字段
    local include_prefix = " " .. icons.include .. " 包含 : "
    local include_display = state.include_pattern
    if include_display == "" then
        include_display = "*.{js,ts,lua}"
    end
    local include_line = include_prefix .. include_display
    
    table.insert(lines, include_line)
    
    if state.input_mode == "include" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #include_prefix, #include_prefix + #include_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #include_prefix, #include_prefix + #include_display })
    end
    
    -- 预览图标
    table.insert(hl, { "SidebarNvimSearchButton", #lines, width - 2, width })
    lines[#lines] = lines[#lines] .. string.rep(" ", width - #lines[#lines] - 2) .. " " .. icons.preview
    
    -- 排除模式字段
    local exclude_prefix = " " .. icons.exclude .. " 排除 : "
    local exclude_display = state.exclude_pattern
    if exclude_display == "" then
        exclude_display = "node_modules,dist"
    end
    local exclude_line = exclude_prefix .. exclude_display
    
    table.insert(lines, exclude_line)
    
    if state.input_mode == "exclude" then
        table.insert(hl, { "SidebarNvimSearchActive", #lines, #exclude_prefix, #exclude_prefix + #exclude_display })
    else
        table.insert(hl, { "SidebarNvimSearch", #lines, #exclude_prefix, #exclude_prefix + #exclude_display })
    end
    
    -- 设置图标
    table.insert(hl, { "SidebarNvimSearchButton", #lines, width - 2, width })
    lines[#lines] = lines[#lines] .. string.rep(" ", width - #lines[#lines] - 2) .. " ⚙"
    
    -- 状态行
    local status_line = string.rep("─", width)
    if state.searching then
        status_line = " 🔄 正在搜索... "
        table.insert(hl, { "SidebarNvimSearchProgress", #lines + 1, 0, #status_line })
    end
    table.insert(lines, status_line)
    
    return lines, hl
end

-- 导出模块函数
local M = {
    close_preview = function()
        state:clear_preview() 
    end,
}

-- 返回侧边栏部分定义
M.section = {
    title = "搜索",
    icon = config.search.icon,
    draw = function(ctx)
        local form_lines, form_hl = draw_search_form(ctx)
        
        -- 绘制搜索结果
        local result_lines = {}
        local result_hl = {}
        
        loclist:draw(ctx, result_lines, result_hl)
        
        -- 合并表单和结果
        local lines = {}
        local hl = {}
        
        vim.list_extend(lines, form_lines)
        for _, highlight in ipairs(form_hl) do
            table.insert(hl, highlight)
        end
        
        vim.list_extend(lines, result_lines)
        for _, highlight in ipairs(result_hl) do
            -- 调整高亮行号以适应表单行
            highlight[2] = highlight[2] + #form_lines
            table.insert(hl, highlight)
        end
        
        if #result_lines == 0 and state.query ~= "" then
            if state.searching then
                table.insert(lines, " 正在搜索...")
                table.insert(hl, { "SidebarNvimSearchProgress", #lines, 0, 12 })
            else
                table.insert(lines, " 未找到结果")
                table.insert(hl, { "SidebarNvimComment", #lines, 0, 16 })
            end
        end
        
        return { lines = lines, hl = hl }
    end,
    
    highlights = {
        groups = {
            SidebarNvimSearch = { fg = "#CCCCCC" },
            SidebarNvimSearchActive = { fg = "#FFFFFF", bg = "#264F78" },
            SidebarNvimSearchButton = { fg = "#00AAFF" },
            SidebarNvimSearchToggle = { fg = "#DDDDDD" },
            SidebarNvimSearchMatch = { fg = "#FFFF00", bold = true },
            SidebarNvimSearchProgress = { fg = "#88FF88" },
            SidebarNvimComment = { fg = "#888888" },
        },
        links = {},
    },
    
    bindings = {
        -- 表单字段导航
        ["<Tab>"] = function()
            if state.input_mode == "search" then
                state.input_mode = "replace"
            elseif state.input_mode == "replace" then
                state.input_mode = "include"
            elseif state.input_mode == "include" then
                state.input_mode = "exclude"
            else
                state.input_mode = "search"
            end
        end,
        
        ["<S-Tab>"] = function()
            if state.input_mode == "search" then
                state.input_mode = "exclude"
            elseif state.input_mode == "replace" then
                state.input_mode = "search"
            elseif state.input_mode == "include" then
                state.input_mode = "replace"
            else
                state.input_mode = "include"
            end
        end,
        
        -- 编辑搜索字段
        ["s"] = function()
            handle_input("search")
        end,
        
        -- 编辑替换字段
        ["r"] = function()
            handle_input("replace")
        end,
        
        -- 编辑包含模式
        ["i"] = function()
            handle_input("include") 
        end,
        
        -- 编辑排除模式
        ["x"] = function()
            handle_input("exclude")
        end,
        
        -- 访问搜索历史
        ["h"] = function()
            browse_history()
        end,
        
        -- 取消正在进行的搜索
        ["<C-c>"] = function()
            state:cancel_search()
        end,
        
        -- 切换大小写敏感
        ["c"] = function()
            state:toggle_setting("case_sensitive")
        end,
        
        -- 切换正则模式
        ["."] = function()
            state:toggle_setting("use_regex") 
        end,
        
        -- 切换全词匹配
        ["w"] = function()
            state:toggle_setting("whole_word")
        end,
        
        -- 执行搜索
        ["<CR>"] = function(line)
            if line <= 4 then
                -- 在输入表单部分
                if line == 1 then
                    handle_input("search")
                elseif line == 2 then
                    handle_input("replace")
                elseif line == 3 then
                    handle_input("include")
                elseif line == 4 then
                    handle_input("exclude")
                end
            else
                -- 在结果部分，打开文件
                local location = loclist:get_location_at(line - 5)  -- 输入表单的偏移量
                if location then
                    vim.cmd("wincmd p")
                    vim.cmd("e " .. location.filepath)
                    vim.fn.cursor(location.line_num, location.col)
                end
            end
        end,
        
        -- 预览文件而不打开
        ["p"] = function(line)
            if line <= 5 then return end  -- 跳过输入表单
            
            local location = loclist:get_location_at(line - 5)  -- 输入表单的偏移量
            if location then
                show_preview(location)
            end
        end,
        
        -- 在位置打开文件
        ["e"] = function(line)
            if line <= 5 then return end  -- 跳过输入表单
            
            local location = loclist:get_location_at(line - 5)  -- 输入表单的偏移量
            if location then
                vim.cmd("wincmd p")
                vim.cmd("e " .. location.filepath)
                vim.fn.cursor(location.line_num, location.col)
            end
        end,
        
        -- 执行替换
        ["R"] = function()
            execute_replace()
        end,
        
        -- 切换结果组
        ["t"] = function(line)
            if line <= 5 then return end  -- 跳过输入表单
            loclist:toggle_group_at(line - 5)  -- 输入表单的偏移量
        end,
        
        -- 关闭预览窗口
        ["q"] = function()
            state:clear_preview()
        end,
    },
    
    setup = function(ctx)
        -- 注册导出函数
        M.execute_search = execute_search
        M.execute_replace = execute_replace
        M.browse_history = browse_history
        M.show_preview = show_preview
        
        -- 初始设置
        vim.api.nvim_set_hl(0, "SidebarNvimSearchMatch", { fg = "#FFFF00", bold = true })
    end,
    
    update = function(ctx)
        -- 如果搜索查询已更改，则更新
        if state.query ~= "" and not state.searching then
            execute_search()
        end
    end,
}

return M