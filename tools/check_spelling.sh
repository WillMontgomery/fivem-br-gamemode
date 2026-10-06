#!/usr/bin/env bash
#
# American spelling in the lines a branch adds.
#
#   bash tools/check_spelling.sh               compare with where HEAD left origin/dev
#   bash tools/check_spelling.sh <ref>         compare with <ref> instead
#   bash tools/check_spelling.sh --self-test   prove the rules below on a scratch repo
#
# The owner is American and so is the product: "in america we say 'color' not
# 'colour'", and later "you keep mis-spelling license." The #399 review then
# found two more words, four times, in lines that round had just written. So
# this reads what a branch ADDS -- committed since it left dev, staged,
# unstaged, and new files git has not been told about -- and fails on a British
# spelling in any of it: the docs, the code's comments, test names and console
# lines alike. AND THE MESSAGES of the commits since it left dev, which are
# history the moment they are pushed: #396's wave A carried three past review.
#
# THE ADDED LINES ONLY, NOT THE TREE. The repo already holds a few thousand
# older ones, and a gate that failed on those would be switched off by the
# first person it stopped. They go when somebody is in that text anyway.
#
# WORDS, NOT NAMES. Fields this code already has (`.armour`, `.colour`,
# `.cancelled`), natives (SetBlipColour, SET_BLIP_COLOUR), a one-word string
# that is a key or an enum value ('catalogue'), a `key =` and anything in
# backticks are names the code must keep, so they are taken out of the line
# before it is read. Anything else that has to stay as it is (a quote from
# somebody else's page, say) carries `spelling-ok` on its line.
#
# BUT A NAME THE LINE DECLARES IS OURS TO CHOOSE, and it is read. A
# `local armour = ...` is not a key, so the `key =` rule must not hide it, and
# `local function fullArmour()` is the words `full armour`: a name declared
# with local, const, let, var or function that starts lower case is read split
# at its capitals. One that starts upper case is a name and is left -- a native
# kept as a local, `local SetBlipColour = SetBlipColour`. #396's wave A added
# both shapes, and the `key =` rule read straight past them.
#
# Vendored third-party code is someone else's and stays as they wrote it, and
# a generated file is checked at its source. Exit 1 on a find, 0 otherwise --
# including when there is nothing to compare with, which it says.

set -uo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'

# THE RULES ABOVE, PROVED RATHER THAN TRUSTED. verify.sh runs this before the
# real check, so a rule that stops catching what it was written for fails the
# build instead of quietly passing everything. A scratch repo with this same
# file in it and two commits off one base: a bad one, whose three declared
# names and one message line must be the ONLY finds beside every shape that
# must pass, and a good one that must pass. The fixture spells the u of each
# British word as @ and sed puts it back, so this file passes its own check.
scrub() { rm -rf "$1" 2>/dev/null || { sleep 1; rm -rf "$1" 2>/dev/null; } || true; }
self_test() {
    local me tmp out rc got want h
    me="$(pwd)/tools/check_spelling.sh"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/check_spelling.XXXXXX" 2>/dev/null) || {
        echo "${RED}FAIL${RST} check_spelling.sh --self-test: no scratch directory"
        return 1
    }
    if ! (
        set -e
        cd "$tmp"
        git init -q .
        git config user.email self-test@example.invalid
        git config user.name self-test
        git config core.autocrlf false
        git config gc.auto 0
        mkdir tools
        cp "$me" tools/check_spelling.sh
        : > a.lua
        git add -A
        git commit -q -m 'base'
        git tag base
        sed 's/@/u/g' > a.lua <<'LINES'
local armo@r = 1
local function fullArmo@r() end
function newColo@r() end
function T.newColo@r() end
local SetBlipColo@r = SetBlipColo@r
t = { armo@r = 1, mateColo@r = 2 }
x = e.armo@r + look.colo@r
SetBlipColo@r(b, 3)
local color, armor = 1, 2
-- `local armo@r` was its old name
LINES
        sed 's/@/u/g' > .git/self-test-msg <<'MSG'
the colo@r of it

not `colo@r`, nor "colo@r"
spelling-ok: colo@r, as the review quoted it
MSG
        git commit -q -a -F .git/self-test-msg
        git tag bad
        git checkout -q base
        printf '%s\n' 'local color = 1' 'local function fullArmor() end' 'function newColor() end' > a.lua
        git commit -q -a -m 'the color of it'
        git tag good
        git checkout -q bad
    ) >/dev/null 2>&1; then
        echo "${RED}FAIL${RST} check_spelling.sh --self-test: could not build the scratch repo"
        scrub "$tmp"
        return 1
    fi
    h=$(git -C "$tmp" log -1 --format=%h bad)
    want=$(sed 's/@/u/g' <<WANT
a.lua:1: local armo@r = 1
a.lua:2: local function fullArmo@r() end
a.lua:3: function newColo@r() end
commit ${h}:1: the colo@r of it
WANT
)
    out=$(cd "$tmp" && bash tools/check_spelling.sh base 2>&1); rc=$?
    got=$(printf '%s\n' "$out" | sed -n 's/^     //p' \
          | grep -v -e '^The owner writes' -e '^A name the code' || true)
    if [ "$rc" -ne 1 ] || [ "$got" != "$want" ]; then
        echo "${RED}FAIL${RST} check_spelling.sh --self-test: the bad commit should fail (exit 1) on exactly"
        printf '%s\n' "$want" | sed 's/^/       /'
        echo "     and it exited $rc saying"
        printf '%s\n' "$out" | sed 's/^/       /'
        scrub "$tmp"
        return 1
    fi
    git -C "$tmp" checkout -q good 2>/dev/null
    out=$(cd "$tmp" && bash tools/check_spelling.sh base 2>&1); rc=$?
    scrub "$tmp"
    if [ "$rc" -ne 0 ]; then
        echo "${RED}FAIL${RST} check_spelling.sh --self-test: the American commit should pass, and it exited $rc saying"
        printf '%s\n' "$out" | sed 's/^/       /'
        return 1
    fi
    echo "${GRN}ok${RST}   the spelling rules hold on a scratch repo: declared names and commit messages read; fields, keys, natives, backticks and quotes left"
    return 0
}

if [ "${1:-}" = '--self-test' ]; then
    self_test
    exit $?
fi

if [ $# -gt 0 ]; then
    base=$(git rev-parse --verify --quiet "$1^{commit}") || {
        echo "${RED}FAIL${RST} check_spelling.sh: '$1' is not a commit"
        exit 2
    }
    against="$1"
else
    base=$(git merge-base HEAD origin/dev 2>/dev/null) || base=''
    against='origin/dev'
fi
if [ -z "$base" ]; then
    echo "${YEL}skip${RST} nothing to compare with (no origin/dev here), so no added lines to read"
    exit 0
fi

# Someone else's code, as they wrote it: every folder with a VENDOR.json, and
# br_ddb's built bundle (its source is read instead). br_ui's and the
# computer's built pages are -diff in .gitattributes, so git shows no lines.
excl=(':(exclude)*/dist/*')
while IFS= read -r v; do
    [ -n "$v" ] && excl+=(":(exclude,literal)${v%/VENDOR.json}")
done < <(git ls-files -- '*VENDOR.json')

# The British forms, each with an American one the owner writes instead. Only
# words that are wrong in American English: no "towards", no "dialogue".
OUR='(colour|honour|behaviour|favour|armour|neighbour|flavour|humour|labour|rumour|vapour|harbour|savour|endeavour|odour|rigour|vigour|parlour|splendour|clamour|valour|candour|tumour|saviour)[a-z]*'  # spelling-ok
RE_='(centre|centres|centred|centring|epicentre|metre|metres|kilometre|kilometres|centimetre|centimetres|millimetre|millimetres|litre|litres|theatre|theatres|fibre|fibres|calibre|sabre|spectre|meagre|lustre|sombre|manoeuvre|manoeuvres|manoeuvred|manoeuvring)'  # spelling-ok
ISE='(real|recogn|organ|initial|normal|serial|deserial|synchron|minim|maxim|priorit|summar|util|apolog|author|custom|emphas|final|optim|visual|categor|memor|stabil|penal|critic|standard|special|material|sanit|token|random|local|central|neutral|capital|general|character|harmon|mobil|item|rational|subsid|equal|global|ideal|personal|symbol|synthes|hypothes|jeopard|scrutin|sympath|pressur|familiar|trivial|formal|legal|steril|digit|parametr|quant|regular|mechan|dramat|vectoris|desensit|sensit|modern|national|stigmat|agon|terror|fantas|patron|monopol|tantal|motor)is(e|ed|es|ing|ation|ations|er|ers)'
YSE='(analys|paralys|catalys)(e|ed|ing)'
LL='(travell|cancell|modell|labell|levell|signall|fuell|totall|marshall|channell|tunnell|counsell|diall|equall|funnell|quarrell|rivall|shovell|swivell|unravell|panell|pencill|revell|grovell|marvell|initiall)(ed|ing|er|ers|ous)'
ONE='(tyre|tyres|kerb|kerbs|grey|greys|greyed|greying|greyer|greyish|greyscale|programme|programmes|licence|licences|defence|defences|offence|offences|pretence|whilst|amongst|judgement|judgements|acknowledgement|acknowledgements|ageing|artefact|artefacts|catalogue|catalogues|catalogued|analogue|cheque|cheques|mould|moulds|moulded|mouldy|aluminium|sceptic|sceptics|sceptical|scepticism|storey|storeys|plough|ploughed|enrol|enrols|enrolment|fulfil|fulfils|fulfilment|instalment|instalments|practise|practised|practises|practising|jewellery|sulphur|cosy|moustache|paediatric|anaesthetic|encyclopaedia|mediaeval)'  # spelling-ok
WORDS="(${OUR}|${RE_}|${ISE}|${YSE}|${LL}|${ONE})"
QUOTED="[\"'][A-Za-z_][A-Za-z0-9_]*[\"']"

# New files git does not track yet are read whole, so the check sees them
# before the first `git add`. Text ones only, outside vendored folders.
untracked=()
vend=$(git ls-files -- '*VENDOR.json' | sed 's#/VENDOR.json$#/#')
while IFS= read -r -d '' u; do
    case "$u" in
        *.lua|*.md|*.sh|*.py|*.js|*.mjs|*.ts|*.tsx|*.css|*.html|*.sql|*.cfg|*.example|*.txt|*.yml|*.yaml|*.toml) ;;
        *) continue ;;
    esac
    case "$u" in */dist/*) continue ;; esac
    skip_=0
    while IFS= read -r v; do
        [ -n "$v" ] && case "$u" in "$v"*) skip_=1 ;; esac
    done <<< "$vend"
    [ "$skip_" -eq 0 ] && untracked+=("$u")
done < <(git ls-files -z --others --exclude-standard)

# One awk program, run over the diff (stdin) and the untracked files, then
# again over the commit messages (mode=msgs). It tags each line with its file
# and line (or its commit and line), takes the names out, adds back the names
# the line declares, and prints the line as written when what is left holds a
# British word. Its last line is the count read: lines, or commits.
PROG='
    function camel(s,    i, c, p, o) {
        o = ""; p = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (p ~ /[a-z0-9]/ && c ~ /[A-Z]/) o = o " "
            o = o c; p = c
        }
        return o
    }
    function declared(text,    rest, d, k, i, n, names, o) {
        o = ""; rest = text
        while (match(rest, /(^|[^A-Za-z0-9_.])(local|const|let|var|function)[ \t]+[A-Za-z_][A-Za-z0-9_, \t]*/)) {
            d = substr(rest, RSTART, RLENGTH)
            rest = substr(rest, RSTART + RLENGTH)
            sub(/^[^A-Za-z0-9_.]?((local|const|let|var)[ \t]+)?(function[ \t]+)?/, "", d)
            n = split(d, names, ",")
            for (i = 1; i <= n; i++) {
                if (!match(names[i], /[A-Za-z_][A-Za-z0-9_]*/)) continue
                k = substr(names[i], RSTART, RLENGTH)
                if (k ~ /^[a-z]/) o = o " " camel(k)
            }
        }
        return o
    }
    function check(file, ln, text,    t, u) {
        lines++
        if (text ~ /spelling-ok/) return
        t = text
        gsub(/`[^`]*`/, " ", t)
        u = declared(t)
        gsub(/\.[A-Za-z_][A-Za-z0-9_]*/, " ", t)
        gsub(quoted, " ", t)
        gsub(/[A-Za-z_][A-Za-z0-9_]*[ \t]*=/, " ", t)
        t = tolower(t " " u)
        if (t ~ ("(^|[^a-z0-9_])" words "([^a-z0-9_]|$)")) print file ":" ln ": " text
    }
    mode == "msgs" {
        if (index($0, "@@@commit ") == 1) { f = "commit " substr($0, 11); n = 0; commits++; next }
        n++; check(f, n, $0); next
    }
    FNR == 1 { stdin = (FILENAME == "-" || FILENAME == "") }
    stdin {
        if ($0 ~ /^diff --git /) { head = 1; next }
        if (head && $0 ~ /^\+\+\+ /) { f = substr($0, 5); sub(/^b\//, "", f); next }
        if ($0 ~ /^@@/) {
            head = 0
            match($0, /\+[0-9]+/)
            n = substr($0, RSTART + 1, RLENGTH - 1) + 0
            next
        }
        if (!head && $0 ~ /^\+/) { check(f, n, substr($0, 2)); n++ }
        next
    }
    { check(FILENAME, FNR, $0) }
    END { print (mode == "msgs" ? commits : lines) + 0 }
'
out=$(
    git diff -U0 --no-color --no-ext-diff --no-renames "$base" -- . "${excl[@]}" \
    | awk -v words="$WORDS" -v quoted="$QUOTED" "$PROG" - ${untracked[@]+"${untracked[@]}"}
)
msgs=$(
    git log --no-color --format='@@@commit %h%n%B' "$base..HEAD" 2>/dev/null \
    | awk -v mode=msgs -v words="$WORDS" -v quoted="$QUOTED" "$PROG"
)
NL=$'\n'
nlines=${out##*"$NL"}
finds=''
[ "$out" != "$nlines" ] && finds=${out%"$NL"*}
ncommits=${msgs##*"$NL"}
if [ "$msgs" != "$ncommits" ]; then
    finds="${finds}${finds:+$NL}${msgs%"$NL"*}"
fi

short=$(git rev-parse --short "$base")
if [ -n "$finds" ]; then
    echo "${RED}FAIL${RST} British spelling in what was added since ${against} (${short}):"
    printf '%s\n' "$finds" | sed 's/^/     /'
    echo "     The owner writes American: color, license, armor, tire, meter, gray, -ize."
    echo "     A name the code has to keep can carry \`spelling-ok\` on its line."
    exit 1
fi
echo "${GRN}ok${RST}   no British spelling in the ${nlines} line(s) and ${ncommits} commit message(s) added since ${against} (${short})"
exit 0
