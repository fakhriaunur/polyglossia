require('polyglossia') -- just in case...

local add_to_callback      = luatexbase.add_to_callback
local remove_from_callback = luatexbase.remove_from_callback
local priority_in_callback = luatexbase.priority_in_callback
local new_attribute        = luatexbase.new_attribute

local node = node

local insert_node_before = node.insert_before
local insert_node_after  = node.insert_after
local remove_node        = node.remove
local has_attribute      = node.has_attribute
local node_copy          = node.copy
local new_node           = node.new
local end_of_math        = node.end_of_math
local getnext            = node.getnext
local getprev            = node.getprev

-- node types according to node.types()
local glue_code    = node.id"glue"
local glyph_code   = node.id"glyph"
local penalty_code = node.id"penalty"
local kern_code    = node.id"kern"
local math_code    = node.id"math"

-- we need some node subtypes
local userkern = 1
local userskip = 0
local removable_skip = {
    [0]  = true, -- userskip
    [13] = true, -- spaceskip
    [14] = true, -- xspaceskip
}

-- we make a new node, so that we can copy it later on
local kern_node = new_node(kern_code)
kern_node.subtype = userkern -- this kern can be removed later on

local function get_kern_node(dim)
    local n = node_copy(kern_node)
    n.kern = dim
    return n
end

local glue_node = new_node(glue_code)
glue_node.subtype = userskip

local function get_glue_node(dim, stretch, shrink)
    local n   = node_copy(glue_node)
    n.width   = dim
    n.stretch = stretch
    n.shrink  = shrink
    return n
end

local penalty_node   = new_node(penalty_code)
penalty_node.penalty = 10000

local function get_penalty_node()
    return node_copy(penalty_node)
end

-- we have here all possible space characters, referenced by their unicode slot
-- number, taken from char-def.lua
local space_chars = {[32] = true, [160] = true, [5760] = true, [6158] = true,
    [8192] = true, [8193] = true, [8194] = true, [8195] = true, [8196] = true,
    [8197] = true, [8198] = true, [8199] = true, [8200] = true, [8201] = true,
    [8202] = true, [8239] = true, [8287] = true, [12288] = true}

-- from nodes-tst.lua, adapted
local function somespace(n)
    if n then
        local id, subtype = n.id, n.subtype
        if id == glue_code then
            -- it is dangerous to remove all the type of glue
            return removable_skip[subtype]
        elseif id == kern_code then
            -- remove only user's kern
            return subtype == userkern
        elseif id == glyph_code then
            return space_chars[n.char]
        end
    end
end

-- idem
local function somepenalty(n, value)
    if n then
        local id = n.id
        if id == penalty_code then
            if value then
                return n.penalty == value
            else
                return true
            end
        end
    end
end

local punct_attr = new_attribute("polyglossia_punct")

local lang_id      = {}
local lang_counter = 0
local left_space   = {}
local right_space  = {}

local function ensure_lang_id(lang)
    if not lang_id[lang] then
        lang_counter = lang_counter + 1
        lang_id[lang] = lang_counter
    end
    return lang_id[lang]
end

local function clear_spaced_characters(lang)
    local id = ensure_lang_id(lang)
    left_space[id]  = {}
    right_space[id] = {}
end

local function illegal_unit(unit)
    if unit then
        texio.write_nl('Illegal spacing unit "'..unit..'".')
    else
        texio.write_nl('Spacing unit is a nil value.')
    end
end

local function add_left_spaced_character(lang, char, kern, unit, rubber)
-- The parameter kern is a number meant as a fraction of the unit.
-- The unit can be "quad" (1em) or "space" (interword space).
-- The parameter rubber is a Boolean value indicating if the inserted space is
-- stretchable and shrinkable (only relevant if the unit is "space").
    local id = ensure_lang_id(lang)
    if unit == "quad" or unit == "space" then
        left_space[id][char] = {}
        left_space[id][char]["kern"] = kern
        left_space[id][char]["unit"] = unit
        left_space[id][char]["rubber"] = rubber
    else
        illegal_unit(unit)
    end
end

local function add_right_spaced_character(lang, char, kern, unit, rubber)
    local id = ensure_lang_id(lang)
    if unit == "quad" or unit == "space" then
        right_space[id][char] = {}
        right_space[id][char]["kern"] = kern
        right_space[id][char]["unit"] = unit
        right_space[id][char]["rubber"] = rubber
    else
        illegal_unit(unit)
    end
end

-- from typo-spa.lua, adapted
local function process(head)
    local current = head
    while current do
        local id = current.id
        if id == glyph_code then
            local attr = has_attribute(current, punct_attr)
            if attr then
                local char = utf8.char(current.char) -- requires Lua 5.3
                local leftspace  = left_space[attr][char]
                local rightspace = right_space[attr][char]
                if leftspace or rightspace then
                    local fontparameters = fonts.hashes.parameters[current.font]
                    local unit, stretch, shrink, spacing_node
                    if leftspace then
                        local prev = getprev(current)
                        if prev then
                            local prevprev = getprev(prev)
                            if somespace(prev) then
                            -- TODO: there is a question here: do we override a preceding space or not?...
                                if somepenalty(prevprev, 10000) then
                                    head = remove_node(head, prevprev)
                                end
                                head = remove_node(head, prev)
                            end
                        end
                        if leftspace.unit == "quad" then
                            unit = fontparameters.quad
                            spacing_node = get_kern_node(leftspace.kern*unit)
                        elseif leftspace.unit == "space" then
                            unit = fontparameters.space
                            if leftspace.rubber then
                                stretch = leftspace.kern*fontparameters.space_stretch
                                shrink  = leftspace.kern*fontparameters.space_shrink
                                spacing_node = get_glue_node(leftspace.kern*unit, stretch, shrink)
                                head = insert_node_before(head, current, get_penalty_node())
                            else
                                spacing_node = get_kern_node(leftspace.kern*unit)
                            end
                        end
                        head = insert_node_before(head, current, spacing_node)
                    end
                    if rightspace then
                        local next = getnext(current)
                        if next then
                            local nextnext = getnext(next)
                            if somepenalty(next, 10000) and somespace(nextnext) then
                                head = remove_node(head, next)
                                head = remove_node(head, nextnext)
                            elseif somespace(next) then
                                head = remove_node(head, next)
                            end
                        end
                        if rightspace.unit == "quad" then
                            unit = fontparameters.quad
                            spacing_node = get_kern_node(rightspace.kern*unit)
                        elseif rightspace.unit == "space" then
                            unit = fontparameters.space
                            if rightspace.rubber then
                                stretch = rightspace.kern*fontparameters.space_stretch
                                shrink  = rightspace.kern*fontparameters.space_shrink
                                spacing_node = get_glue_node(rightspace.kern*unit, stretch, shrink)
                                head, current = insert_node_after(head, current, get_penalty_node())
                            else
                                spacing_node = get_kern_node(rightspace.kern*unit)
                            end
                        end
                        head, current = insert_node_after(head, current, spacing_node)
                    end
                end
            end
        elseif id == math_code then
            -- warning: this is a feature of luatex > 0.76
            current = end_of_math(current) -- weird, can return nil .. no math end?
        end
        current = getnext(current) -- no error even if current is nil
    end
    return head
end

local function activate(lang)
    local id = ensure_lang_id(lang)
    -- We set the punctuation attribute to a language id here. This is
    -- important to be able to intermix languages with different spacings
    -- in one paragraph.
    tex.setattribute(punct_attr, id)
    for _, callback_name in ipairs{ "pre_linebreak_filter", "hpack_filter" } do
        if not priority_in_callback(callback_name, "polyglossia-punct.process") then
            add_to_callback(callback_name, process, "polyglossia-punct.process", 1)
        end
    end
end

local function deactivate()
    tex.setattribute(punct_attr, -0x7FFFFFFF) -- this value means "unset"
    -- Though it would make compilation slightly faster, it is not possible to
    -- safely uncomment the following lines. Imagine the following case: you
    -- start a paragraph by some spaced punctuation text, then, in the same
    -- paragraph, you change the language to something else, and thus call the
    -- following lines. This means that, at the end of the paragraph, the
    -- function won't be in the callback, so the beginning of the paragraph
    -- won't be processed by it.
    -- if priority_in_callback(callback_name, "polyglossia-punct.process") then
    --     remove_from_callback(callback_name, "polyglossia-punct.process")
    -- end
end

polyglossia.activate_punct             = activate
polyglossia.deactivate_punct           = deactivate
polyglossia.add_left_spaced_character  = add_left_spaced_character
polyglossia.add_right_spaced_character = add_right_spaced_character
polyglossia.clear_spaced_characters    = clear_spaced_characters
