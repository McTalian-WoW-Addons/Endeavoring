---
name: plan
description: Plan a feature from a GitHub issue with technical design and implementation roadmap
argument-hint: Issue number (e.g., #123)
agent: agent
tools: ['vscode', 'read', 'edit', 'agent', 'search', 'todo', 'web', 'vscode.mermaid-chat-features/renderMermaidDiagram', 'github.vscode-pull-request-github/issue_fetch']
---

# Plan - Feature Planning from GitHub Issue

You are collaborating with the user to plan a feature from a GitHub issue. Your goal is to transform the issue requirements into a detailed technical plan with clear implementation phases.

## Input Requirement

**This workflow requires a GitHub issue number.**

- Extract issue number from formats like: `#123`, `123`, `issue 123`
- If no issue number provided, ask: "Please provide an issue number to plan (e.g., `/plan #123`). Create an issue first at https://github.com/McTalian-WoW-Addons/Endeavoring/issues/new/choose"

**Fetch the issue**:
1. Call: `github-pull-request_issue_fetch(owner: "McTalian-WoW-Addons", repo: "Endeavoring", issue_number: 123)`
2. Extract key information:
   - Issue title and description
   - Labels (complexity, priority indicators)
   - Any linked PRs or related issues
   - Discussion context from comments
3. Acknowledge: "Planning from issue #123: [title]"

## Planning Process

### Step 1: Clarify the Feature

**Ask exploratory questions** to understand the vision:
- What problem does this solve for users?
- What does success look like?
- Are there similar features in WoW or other addons we can learn from?
- Any must-have vs. nice-to-have aspects?

**Define scope boundaries**:
- What's in scope for this feature?
- What's explicitly out of scope?
- Are there future extensions to consider in the design?

### Step 2: Research & Discovery

#### WoW API Investigation
- What `C_*` APIs are needed? (Check wow-ui-source)
- Are there relevant Blizzard frames to hook or reference?
- Any events to register for?
- Potential API limitations or gotchas?

#### Architecture Fit
- Which layer(s) does this touch?
  - **Services/**: New WoW API abstractions needed?
  - **Data/**: Database schema changes?
  - **Features/**: New UI components?
  - **Integrations/**: Blizzard frame hooks?
- How does it integrate with existing code?
- Any refactoring needed to support it?

#### Similar Patterns
Search the codebase and wow-ui-source for:
- How did Blizzard implement something similar?
- What patterns exist in our codebase we can follow?
- What can we reuse vs. build new?

### Step 3: Technical Design

Break down the feature into technical components:

#### Data Model
- What data needs to be stored? (SavedVariables impact)
- Schema changes to existing structures?
- New profiles/tracking needed?
- Timestamps for sync/delta updates?
- Migration strategy if changing existing data?

#### Sync Protocol Impact
- Does this data sync across characters/players?
- New message types needed?
- Gossip propagation considerations?
- Rate limiting implications?

#### API Abstraction
- What Services need to be created/modified?
- Clean interface design
- Error handling strategy
- Nil safety for new APIs

#### UI/UX Design
- Where does the UI live? (New frame vs. integrate existing)
- User interaction flow
- Visual design (follow Blizzard patterns from wow-ui-source)
- Accessibility considerations
- Settings/options needed?

#### Edge Cases & Error Handling
- What can go wrong?
- How do we handle missing data?
- What if APIs return nil/fail?
- Network issues (for sync features)?
- Large dataset considerations (guild size, activity volume)?

### Step 4: Break Into Tasks

Create a **phased implementation plan**:

#### Phase 1 - Foundation
Core infrastructure without UI:
- Data schema changes
- Service layer abstractions
- Basic functionality
- Unit-testable components

#### Phase 2 - UI/UX
User-facing components:
- Frame/widget creation
- Integration with existing UI
- User interactions
- Visual polish

#### Phase 3 - Integration
Connecting everything:
- Blizzard frame hooks
- Event handling
- Settings/configuration
- Feature toggles

#### Phase 4 - Polish & Edge Cases
Making it production-ready:
- Error handling
- Edge case coverage
- Performance optimization
- Documentation

**Mark each task with**:
- Brief description (what needs to be done)
- Estimated complexity (Simple/Medium/Complex)
- Dependencies (what must be done first)
- Files affected (likely)

### Step 5: Risk Assessment

Identify potential challenges:

#### Technical Risks
- **API limitations**: Can we actually do X with available APIs?
- **Performance**: Will this scale with large guilds/datasets?
- **Compatibility**: Breaking changes to existing features?

#### UX Risks
- **Complexity**: Is it too complicated for users?
- **Discoverability**: Will users find this feature?
- **Conflicts**: Does it clash with other addon features?

#### Scope Risks
- **Scope creep**: Is this getting too big?
- **Timeline**: Realistic given other priorities?
- **Maintenance**: Ongoing maintenance burden?

For each risk, suggest mitigation strategies.

### Step 6: Testing Strategy

How will we validate this works?

#### Manual Testing
- Key scenarios to test
- Edge cases to verify
- Different character states (has house, no house, etc.)
- Guild vs. non-guild contexts

#### In-Game Validation
- Test with real APIs (not just stubs/guesses)
- Midnight alpha/beta testing needs
- Multiple characters/accounts if needed

#### Rollout Strategy
- Feature flag for gradual rollout?
- Beta users first?
- Rollback plan if issues emerge?

### Step 7: Documentation Plan

What needs documenting?

- **Code comments**: Complex logic, API quirks
- **Architecture docs**: If new patterns emerge
- **User-facing**: How do users use this feature?
- **Changelog**: What to tell users in release notes

### Step 8: Output Actionable Roadmap

Present the complete plan in sections:

```markdown
## Feature Plan: [Feature Name]

### Overview
[1-2 paragraph summary of what we're building and why]

### User Experience
[Describe what the user sees/does]

### Technical Approach
**Data Model**: [Schema changes, new structures]
**API Dependencies**: [C_* APIs needed, events, etc.]
**Architecture Changes**: [Services/Data/Features affected]
**Sync Impact**: [If applicable]

### Implementation Phases

#### Phase 1: Foundation
- [ ] Task 1 (Complexity) - Files: [...]
- [ ] Task 2 (Complexity) - Files: [...]

#### Phase 2: UI/UX
- [ ] Task 1 (Complexity) - Files: [...]

[etc.]

### Risks & Mitigations
- **Risk 1**: [Description] → Mitigation: [Strategy]

### Testing Approach
[How we'll validate this works]

### Open Questions
- [ ] Question 1: [Thing to investigate/decide]
- [ ] Question 2: [Thing to investigate/decide]

### Next Steps
1. [Immediate first action]
2. [What comes after]
```

### Step 9: Save and Update Documentation

**Save the plan**:
- Save the plan as `.github/plans/issue-{number}.md`
- This allows `/implement #{number}` to reference the plan automatically
- Include issue number and link in the plan document header

**Update project documentation**:
- Add this plan to [development-status.md](../docs/development-status.md)
- Create a new phase or update existing phase
- Add tasks to the roadmap

**Update the issue** (optional):
- Post a comment with a link to the saved plan
- Update labels if complexity estimate changed during planning

## Tone & Approach

- ✅ **Collaborative exploration**: "What if we...?" "Have you considered...?"
- ✅ **Think out loud**: Share reasoning, trade-offs, alternatives
- ✅ **Ask questions**: Better to clarify upfront than assume
- ✅ **Reference the codebase**: "Looking at how Tasks.lua works..."
- ✅ **Be realistic**: Call out complexity and challenges honestly
- ✅ **Offer options**: Present approaches with pros/cons

## Special Considerations for Endeavoring

### Consider Sync Implications
Almost any data feature needs sync consideration:
- Will neighbors see this?
- Does it need gossip propagation?
- BattleTag tracking required?

### Neighborhood Context
Features often interact with neighborhood state:
- Active endeavor
- Guild membership
- Plot ownership
- Neighbor relationships

### WoW Housing Beta Status
Midnight is new - APIs might change:
- Design for flexibility
- Graceful degradation if APIs change
- Easy to update if Blizzard patterns shift

### Existing Phase Work
- Phase 2 (Options UI) is pending
- Phase 3/3.5 (Sync) is complete
- Phase 4 (Polish) is upcoming
- How does this feature fit into the roadmap?

## Example Usage

**From GitHub issue**:
```
/plan #42
```
→ Loads issue #42, creates detailed implementation plan, saves to `.github/plans/issue-42.md`

**Typical workflow**:
1. Create issue: https://github.com/McTalian-WoW-Addons/Endeavoring/issues/new/choose
2. Run `/plan #123` to create technical design
3. Plan is saved for `/implement #123` to reference
4. Update development-status.md with planned work

The output should give you confidence to start implementing, knowing you've thought through the major considerations and have a clear roadmap.
