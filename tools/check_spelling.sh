#!/usr/bin/env bash
#
# American spelling in the lines a branch adds.
#
#   bash tools/check_spelling.sh           compare with where HEAD left origin/dev
#   bash tools/check_spelling.sh <ref>     compare with <ref> instead
#
# The owner is American and so is the product: "in america we say 'color' not
# 'colour'", and later "you keep mis-spelling license." The #399 review then
# found two more words, four times, in lines that round had just written. So
# this reads what a branch ADDS -- committed since it left dev, staged,
# unstaged, and new files git has not been told about -- and fails on a British
# spelling in any of it: the docs, the code's comments, test names and console
# lines alike.
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
# Vendored third-party code is someone else's and stays as they wrote it, and
# a generated file is checked at its source. Exit 1 on a find, 0 otherwise --
# including when there is nothing to compare with, which it says.

set -uo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'

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

# One awk over the diff (stdin) and the untracked files. It tags each added line
# with its file and line, takes the names out, and prints the line as written
# when what is left holds a British word. Its last line is the count read.
out=$(
    git diff -U0 --no-color --no-ext-diff --no-renames "$base" -- . "${excl[@]}" \
    | awk -v words="$WORDS" -v quoted="[\"'][A-Za-z_][A-Za-z0-9_]*[\"']" '
        function check(file, ln, text,    t) {
            lines++
            if (text ~ /spelling-ok/) return
            t = text
            gsub(/`[^`]*`/, " ", t)
            gsub(/\.[A-Za-z_][A-Za-z0-9_]*/, " ", t)
            gsub(quoted, " ", t)
            gsub(/[A-Za-z_][A-Za-z0-9_]*[ \t]*=/, " ", t)
            t = tolower(t)
            if (t ~ ("(^|[^a-z0-9_])" words "([^a-z0-9_]|$)")) print file ":" ln ": " text
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
        END { print lines + 0 }
    ' - ${untracked[@]+"${untracked[@]}"}
)
NL=$'\n'
nlines=${out##*"$NL"}
finds=''
[ "$out" != "$nlines" ] && finds=${out%"$NL"*}

short=$(git rev-parse --short "$base")
if [ -n "$finds" ]; then
    echo "${RED}FAIL${RST} British spelling in lines added since ${against} (${short}):"
    printf '%s\n' "$finds" | sed 's/^/     /'
    echo "     The owner writes American: color, license, armor, tire, meter, gray, -ize."
    echo "     A name the code has to keep can carry \`spelling-ok\` on its line."
    exit 1
fi
echo "${GRN}ok${RST}   no British spelling in the ${nlines} line(s) added since ${against} (${short})"
exit 0
