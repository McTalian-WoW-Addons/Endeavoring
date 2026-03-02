---
name: implement
description: Implement a feature from a GitHub issue with plan integration
argument-hint: Issue number (e.g., #123)
agent: agent
tools: ['vscode', 'execute', 'read', 'edit', 'search', 'web', 'todo', 'github.vscode-pull-request-github/issue_fetch']
---

# Implement - Issue-Based Implementation

You are implementing a feature or enhancement based on a GitHub issue. This workflow loads the issue content, checks for an existing implementation plan, and executes the work systematically.

## Implementation Process

### Step 1: Load Issue Context

**Parse the issue number** from the user's command:
- Extract issue number from formats like: `#123`, `123`, `issue 123`
- If no number provided, ask the user which issue to implement

**Fetch the issue** using GitHub tools:
1. Fetch issue content: `github-pull-request_issue_fetch(owner: "McTalian-WoW-Addons", repo: "Endeavoring", issue_number: 123)`
2. Extract key information:
   - Issue title and description
   - Labels (complexity, priority indicators)
   - Any linked PRs or related issues
   - Discussion context from comments

### Step 2: Check for Implementation Plan

**Look for existing plan document**:
- Search for plan document in issue comments (user may have posted one)
- Search for plan document by convention: `.github/plans/issue-{number}.md`
- Search workspace for related planning documents

**If plan exists**:
- Load the plan document
- Use it as the implementation roadmap
- Validate that the plan still aligns with current issue description
- Call out any discrepancies between plan and issue

**If no plan exists**:
- Ask user: "No implementation plan found. Would you like to:"
  - A) Create a plan first with `/plan #123`
  - B) Implement directly from issue description (for simple issues)
  - C) Continue with quick planning phase now

For option C, conduct abbreviated planning (5-10 minutes):
- Key technical approaches
- Files to modify
- Major steps
- Risks to watch for

### Step 3: Pre-Implementation Checks

**Validate environment**:
- Check git status is clean (warn if uncommitted changes)
- Confirm current branch (main or feature branch?)
- Suggest creating feature branch: `git checkout -b feature/issue-{number}-brief-name`

**Load necessary context**:
- Read relevant files mentioned in issue/plan
- Search for related code patterns in codebase
- Check WoW API documentation if needed (wow-ui-source)
- Load conditional instructions for file types you'll be editing

**Review complexity**:
- Issue labels indicate complexity level
- Adjust approach based on complexity:
  - **Low complexity**: Direct implementation
  - **Medium complexity**: Phase-based approach with validation checkpoints
  - **High complexity**: Suggest breaking into sub-tasks or using `/refactor` for major changes

### Step 4: Execute Implementation

**Follow the plan** (if available) or **implement from issue description**:

**For each implementation step**:
1. Announce what you're working on
2. Make the necessary code changes
3. Explain key decisions as you go
4. Call out any deviations from the plan (with reasoning)

**Coding standards** (automatically loaded for Lua files):
- Follow project conventions from conditional instructions
- Use proper nil guards and defensive coding
- Match existing code style
- Add comments for complex logic

**Incremental validation**:
- After each logical chunk, check for errors: `get_errors()`
- Fix syntax/lint errors before proceeding
- Validate that changes compile: `make toc_check` or similar

### Step 5: Testing Guidance

**Manual testing readiness**:
- Provide clear testing instructions for the feature
- List key scenarios to test in WoW client
- Call out edge cases from the plan/issue
- Suggest `make dev` or `make watch` for rapid testing iteration

**Test checklist from issue**:
- If issue includes acceptance criteria, create test checklist
- Mark each criterion with how to validate it
- Note any testing limitations (e.g., "requires next endeavor cycle")

### Step 6: Documentation Updates

**Update relevant docs**:
- Code comments for complex logic
- Update [development-status.md](../docs/development-status.md) if this affects roadmap
- Update architecture docs if introducing new patterns
- Add entries to changelog (if applicable)

**Issue linkage**:
- Ensure commit messages reference the issue: `Implements #123: Brief description`
- Update issue with progress comments (or remind user to)

### Step 7: Completion Summary

**Provide implementation summary**:
```markdown
## Implementation Complete: [Issue Title]

### Changes Made
- File 1: [What changed]
- File 2: [What changed]

### Key Decisions
- Decision 1: [Rationale]
- Decision 2: [Rationale]

### Deviations from Plan
- Deviation 1: [Why and what was done instead]

### Testing Instructions
1. Run `make dev` to build
2. Launch WoW and test:
   - Scenario 1: [How to test]
   - Scenario 2: [How to test]
3. Key edge cases to verify:
   - Edge case 1
   - Edge case 2

### Next Steps
- [ ] Test in WoW client
- [ ] Verify no LUA errors
- [ ] Check all acceptance criteria from issue
- [ ] Commit with message: "Implements #123: [brief description]"
- [ ] Update issue with results
- [ ] Close issue if complete (or note remaining work)
```

### Step 8: Offer Follow-Up Actions

**Ask if user wants you to**:
- Create commit with proper message
- Update issue with implementation notes
- Generate PR description (if on feature branch)
- Create follow-up issues for discovered work
- Run additional validation checks

## Special Considerations

### Complex/Multi-Phase Issues

For high-complexity issues (per labels or plan):
- **Break into sub-phases**: Implement foundations, then UI, then polish
- **Checkpoint frequently**: Validate at end of each phase
- **Consider `/refactor`**: For large structural changes, delegate to refactoring workflow
- **Create sub-tasks**: If issue is too large, suggest breaking into multiple issues

### API Investigation During Implementation

If you discover API limitations or missing information:
- Document findings as you go
- Add notes to implementation summary
- Suggest updating issue with new insights
- Consider experimental implementation with fallback

### Blocked Work

If you hit a blocker during implementation:
- **Stop and document**: What's blocking, why, what's needed
- **Suggest alternatives**: Different approach? Defer part to future issue?
- **Update issue**: Add comment about blocker
- **Park progress**: Use `/park` to save partial work with blocker notes

## Workflow Integration

**Before `/implement`**:
- Optionally run `/plan #123` to create implementation roadmap
- Ensure issue is well-defined with clear acceptance criteria

**During `/implement`**:
- Use `/refactor` for complex structural changes
- `make watch` in background for rapid WoW client testing
- Check errors frequently with `get_errors()`

**After `/implement`**:
- Use `/review` for code quality check before committing
- Test thoroughly in WoW client
- Update issue and close if complete
- Use `/park` if work is partial or interrupted

## Issue Format Expectations

This workflow works best with well-structured issues:

**Good issue structure**:
- Clear problem statement
- Proposed solution or acceptance criteria
- Complexity label
- Related files mentioned
- Edge cases or considerations noted

**If issue is unclear**:
- Ask clarifying questions before starting
- Suggest updating issue with answers
- Consider brief planning phase to clarify approach

## Examples

**Simple implementation**:
```
/implement #42
```
→ Loads issue #42, checks for plan, implements directly

**With plan document**:
```
/implement #42
```
→ Finds `.github/plans/issue-42.md`, uses it as roadmap

**Iterative development**:
```
/implement #42
[work on phase 1]
/park
---
[next session]
/resume
[continue with phase 2]
```

## Output Style

- ✅ **Action-oriented**: Focus on making progress
- ✅ **Explain decisions**: Share reasoning for technical choices
- ✅ **Show progress**: Update as you complete each step
- ✅ **Flag blockers early**: Don't struggle silently
- ✅ **Think incrementally**: Validate frequently, build in phases
- ✅ **Reference issue**: Keep implementation aligned with requirements

Your goal is to transform the issue requirements into working, tested, documented code efficiently and reliably.
