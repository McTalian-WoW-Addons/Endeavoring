# Custom Prompt Workflows

This directory contains custom prompt files that provide specialized workflows for common development tasks in VS Code's GitHub Copilot Chat.

## What are Prompt Files?

Prompt files are reusable chat instructions that can be invoked with slash commands (e.g., `/refactor`). They:
- Provide consistent, structured workflows for complex tasks
- Leverage different AI models for their specific strengths
- Include built-in validation and error recovery
- Make complex multi-step processes simple and reliable

## Context Awareness

When executing workflows, different types of context are automatically available:

**Always Available**:
- `.github/copilot-instructions.md` - Core collaboration guidelines, model selection, workflow references
- Project structure and file organization

**Auto-Loaded by File Type**:
- **Editing Lua files** → `.github/instructions/lua-development.instructions.md` and `wow-api.instructions.md` automatically load
- Provides language-specific patterns, conventions, and WoW API guidance

**On-Demand** (linked when needed):
- Architecture, database schema, sync protocol, glossary, resources
- Loaded via explicit references in conversation

This layered approach ensures workflows have just the right context without overwhelming the agent.

## Available Workflows

### 🔧 `/refactor [description]` - Smart Refactoring

**Purpose**: Handle complex multi-file refactoring with precision and safety.

**When to use**:
- Moving code between multiple files
- Renaming classes/functions across the codebase
- Architectural restructuring
- Any refactoring involving more than one file

**How it works**:
1. You describe what you want to refactor
2. Claude Sonnet 4.5 (orchestrator) creates a safety checkpoint and detailed plan
3. GPT-5.1-Codex-Max (subagent) executes precise code changes
4. Claude validates each step before proceeding
5. Provides rollback instructions if issues arise

**Why this approach**:
- **GPT-5.1-Codex-Max excels at**: Multi-line replacements, preserving whitespace/indentation, finding ALL references
- **Claude Sonnet 4.5 excels at**: Planning, validation, recovery, communicating with you
- Together, they provide accuracy AND safety

**Example**:
```
/refactor Extract the leaderboard logic into a separate module
```

**Output**:
- Step-by-step plan for approval
- Git checkpoint reminder
- Validated changes at each step
- Syntax and build validation
- Rollback instructions if needed

**Best for**:
- Multi-file refactoring
- Large-scale renaming
- Architectural changes
- When previous attempts struggled with multi-line edits

---

### 📋 `/plan #issue` - Feature Planning from GitHub Issue

**Purpose**: Transform a GitHub issue into a detailed technical implementation plan.

**When to use**:
- Before implementing any new feature or enhancement
- When breaking down complex work from an issue
- To create a clear technical roadmap before coding
- As the first step in the issue-based development workflow

**How it works**:
1. Requires GitHub issue number (e.g., `#123`)
2. Loads issue content via GitHub API (title, description, labels, comments)
3. Analyzes technical approaches and trade-offs
4. Identifies dependencies and edge cases
5. Creates step-by-step implementation roadmap
6. Generates technical design documentation
7. **Saves plan** to `.github/plans/issue-{number}.md` for `/implement` to use

**Example**:
```
/plan #42
```

**Output**:
- Problem and solution analysis from issue requirements
- Technical approach with trade-offs
- Dependency identification
- Implementation roadmap with phases
- Architecture diagrams (if applicable)
- Saved plan document at `.github/plans/issue-42.md`

**Note**: Create the GitHub issue first at https://github.com/McTalian-WoW-Addons/Endeavoring/issues/new/choose

---

### ⚙️ `/implement #issue` - Issue-Based Implementation

**Purpose**: Implement a feature from a GitHub issue with automatic plan integration.

**When to use**:
- Executing work from a well-defined GitHub issue
- Following an implementation plan from `/plan`
- Converting issue requirements into working code

**How it works**:
1. Loads issue content via GitHub API
2. Checks for existing plan document (`.github/plans/issue-{number}.md`)
3. If no plan exists, offers to create one or implement directly
4. Validates environment (git status, branch)
5. Executes implementation step-by-step
6. Validates changes incrementally
7. Provides testing instructions
8. Generates implementation summary

**Example**:
```
/implement #42
```

**Output**:
- Step-by-step implementation with explanations
- Code changes across relevant files
- Incremental validation and error checking
- Testing instructions for WoW client
- Implementation summary with commit message
- Documentation updates

**Best combined with**: `/plan #42` first to create roadmap, then `/implement #42` to execute.

---

### 🅿️ `/park` - Save Session

**Purpose**: Cleanly end a development session and create handoff summary.

**When to use**:
- End of work session (need to step away)
- Before major context switch
- Preparing to share work with others
- Want to continue in fresh agent context

**How it works**:
1. Reviews what was accomplished in this session
2. Updates relevant documentation
3. Generates comprehensive handoff summary
4. Provides copy/paste-ready output for `/resume`

**Example**:
```
/park
```

**Output**:
- Updated project documentation
- Structured handoff summary including:
  - What was completed
  - Files modified
  - Key decisions made
  - Testing status
  - Recommended next steps

**Best practice**: Copy the handoff summary and paste it when starting your next session with `/resume`.

---

### ▶️ `/resume [handoff]` - Restore Context

**Purpose**: Continue work seamlessly from a parked session.

**When to use**:
- Starting work after using `/park`
- Picking up where you left off
- Onboarding into existing work stream

**How it works**:
1. Parses the handoff summary
2. Validates current state matches what was described
3. Confirms understanding and next steps
4. Proceeds with the work

**Example**:
```
/resume
[paste handoff summary from /park]
```

**Output**:
- Validation of current state
- Confirmation of what was accomplished
- Clear statement of next objective
- Ready to continue working

---

### 🔍 `/review [scope]` - Code Review

**Purpose**: Get expert feedback on code quality and WoW addon best practices.

**When to use**:
- After implementing a feature
- Before committing major changes
- Want feedback on approach
- Learning WoW addon development

**How it works**:
1. Analyzes code from WoW addon developer perspective
2. Identifies potential issues
3. Suggests improvements
4. Validates against project conventions

**Example**:
```
/review Services/AddonMessages.lua
```

**Output**:
- Code quality feedback
- Potential issues identified
- Improvement suggestions
- Best practices guidance

---

## Model Selection Strategy

Different AI models have different strengths. This workflow system leverages the right model for each task:

### GPT-5.1-Codex-Max
**Best for**:
- Complex multi-file refactoring
- Multi-line code changes
- Architectural restructuring  
- Updating call sites across codebase

**Why**: Superior accuracy at preserving exact whitespace, indentation, and code structure. Better at finding ALL references when renaming.

**Used by**: `/refactor` (as subagent for code execution)

### Claude Sonnet 4.5 (Default)
**Best for**:
- General development and features
- High-level planning and architecture
- Code review and analysis
- User communication
- Workflow orchestration

**Why**: Excellent at understanding context, making decisions, explaining concepts, and coordinating complex workflows.

**Used by**: All prompts (orchestration), general chat

## Workflow Integration

These prompts are designed to work together:

**Issue-Based Development Flow** (Recommended):
```
[Create issue]         → https://github.com/McTalian-WoW-Addons/Endeavoring/issues/new
/plan #42              → Load issue, create implementation plan
                       → Plan saved to .github/plans/issue-42.md
/implement #42         → Load issue + plan, execute implementation
                       → Work through phases with validation
/review [files]        → Quality check before committing
[commit & test]        → Commit with: "Implements #42: description"
/park                  → Document completion

---
[Next session]
/resume [handoff]      → Pick up where you left off
```

**Quick Fix/Iteration Flow**:
```
[implement changes]
/review               → Quick quality check
[fix issues]
/park                 → End session
```

**Big Refactor Flow**:
```
/refactor [goal]      → Execute with precision
[validate in-game]    → Test changes
/park                 → Document what was done
```

## Tips for Effective Use

### For `/refactor`:
- **Be specific** about what you want to refactor
- **Trust the process** - let it create checkpoints and plan
- **Validate each step** before continuing (it will guide you)
- **Have git status clean** before starting
- **Don't skip the checkpoint** - you'll appreciate it if something goes wrong

### For `/plan`:
- **Create issue first** - `/plan` requires a GitHub issue number
- **Ask for planning early** - design before coding saves time
- **Engage with questions** - the back-and-forth improves the plan
- **Plans are saved automatically** - to `.github/plans/issue-{number}.md`
- **Reference the plan** during implementation
- **Update the plan** if you discover new requirements during implementation

### For `/implement`:
- **Plan first** - run `/plan #42` before `/implement #42` for best results
- **Works without plan** - can implement directly from issue if simple
- **Watch for blockers** - workflow will pause and document if blocked
- **Validate incrementally** - checks errors after each logical chunk
- **Test thoroughly** - use `make watch` for rapid iteration in WoW client
- **Keep issue updated** - workflow guides you to update issue with progress

### For `/park` and `/resume`:
- **Park regularly** - at natural stopping points
- **Copy handoff immediately** - paste into notes or next session
- **Resume at start of session** - restores context efficiently
- **Trust the validation** - it checks that state matches handoff

### General:
- **Let each tool do its job** - don't micromanage the workflows
- **Follow the checkpoints** - they exist for safety
- **Provide feedback** - if a workflow isn't working, suggest improvements

## Customization

These prompt files are part of the project and can be modified:

1. Edit `.github/prompts/*.prompt.md` files directly
2. Follow the existing structure (YAML frontmatter + markdown body)
3. Test changes by using the slash command
4. Commit improvements to share with team

## Learn More

- [VS Code Prompt Files Documentation](https://code.visualstudio.com/docs/copilot/customization/prompt-files)
- [Custom Instructions Guide](https://code.visualstudio.com/docs/copilot/customization/custom-instructions)
- [Project Copilot Instructions](../copilot-instructions.md)
- [Development Status](../docs/development-status.md#development-workflows)
