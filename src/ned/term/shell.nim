# ── shell integration: the shell marks each prompt, command line, output and exit code (OSC 133) ──

const NedBashSI = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by bash.
if [ -z "$__ned_si" ]; then
  __ned_si=1
  [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
  __ned_si_prompt() { local s=$?; printf '\033]133;D;%s\007\033]133;A\007' "$s"; return $s; }
  __ned_si_ps1() { case "$PS1" in *'133;B'*) ;; *) PS1="$PS1"'\[\033]133;B\007\]' ;; esac; }
  if [ "$(declare -p PROMPT_COMMAND 2>/dev/null | cut -c1-10)" = "declare -a" ]; then
    PROMPT_COMMAND=(__ned_si_prompt "${PROMPT_COMMAND[@]}" __ned_si_ps1)
  else
    PROMPT_COMMAND="__ned_si_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __ned_si_ps1"
  fi
  PS0="${PS0}"$'\033]133;C\007'
fi
"""

const NedZshEnv = """# ned: shell integration — your own .zshenv, then ned's .zshrc (which reads yours)
__ned_si_dir="$ZDOTDIR"
ZDOTDIR="${NED_USER_ZDOTDIR:-$HOME}"
[[ -r "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
NED_USER_ZDOTDIR="$ZDOTDIR"
ZDOTDIR="$__ned_si_dir"
"""

const NedZshRc = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by zsh.
ZDOTDIR="$NED_USER_ZDOTDIR"
unset NED_USER_ZDOTDIR __ned_si_dir
[[ -r "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
__ned_si_precmd() { local s=$?; print -rn -- $'\e]133;D;'"$s"$'\a\e]133;A\a'; return $s }
__ned_si_b() { [[ "$PS1" == *'133;B'* ]] || PS1="$PS1"$'%{\e]133;B\a%}' }
__ned_si_preexec() { print -rn -- $'\e]133;C\a' }
precmd_functions=(__ned_si_precmd $precmd_functions __ned_si_b)
preexec_functions+=(__ned_si_preexec)
"""

const NedFishSI = """# ned: shell integration (OSC 133 marks: prompt, command, output, exit code). Made by ned, read by fish.
function __ned_si_prompt --on-event fish_prompt
    printf '\e]133;D;%s\a\e]133;A\a' "$__ned_si_status"
end
function __ned_si_pre --on-event fish_preexec
    printf '\e]133;C\a'
end
function __ned_si_post --on-event fish_postexec
    set -g __ned_si_status $status
end
if functions -q fish_prompt; and not functions -q __ned_si_orig_prompt
    functions -c fish_prompt __ned_si_orig_prompt
    function fish_prompt
        __ned_si_orig_prompt
        printf '\e]133;B\a'
    end
end
"""

proc shellIntegration(shell: string): (seq[string], seq[(string, string)]) =
  ## the arguments and environment that make bash, zsh or fish send OSC 133 marks (their own startup files are
  ## still read); nothing for other shells
  if not cfgTermIntegration: return
  let name = extractFilename(shell)
  let dir = privDir() / "shell"
  try:
    createDir(dir)
    if name.startsWith("bash"):
      writeFile(dir / "bash.sh", NedBashSI)
      return (@["--init-file", dir / "bash.sh"], @[])
    if name.startsWith("zsh"):
      createDir(dir / "zsh")
      writeFile(dir / "zsh" / ".zshenv", NedZshEnv)
      writeFile(dir / "zsh" / ".zshrc", NedZshRc)
      let user = getEnv("ZDOTDIR", getHomeDir().strip(leading = false, chars = {'/'}))
      return (@[], @[("ZDOTDIR", dir / "zsh"), ("NED_USER_ZDOTDIR", user)])
    if name.startsWith("fish"):
      writeFile(dir / "fish.fish", NedFishSI)
      return (@["--init-command", "source " & quoteShell(dir / "fish.fish")], @[])
  except CatchableError: discard
