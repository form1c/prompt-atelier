import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import os from 'node:os'
import EmptyState from '../../frontend/src/components/EmptyState.vue'

// AP-01 carries no frontend logic yet. What this suite proves is that the
// toolchain is actually wired up: Vitest resolves the Vue plugin, single file
// components compile, and jsdom is available. Without that check "Vitest runs"
// would only mean "Vitest found no files", which is not the same thing.
//
// The component under the microscope was App.vue until AP-09. It is a shared
// building block now: App.vue has become the root of a routed application and
// no longer mounts without one, which would make this suite a test of the
// router rather than of the toolchain.
describe('toolchain', () => {
  it('compiles and mounts a single file component', () => {
    const wrapper = mount(EmptyState, { props: { title: 'PromptAtelier' } })
    expect(wrapper.find('h2').text()).toBe('PromptAtelier')
  })

  it('provides a DOM environment', () => {
    expect(typeof document).toBe('object')
    expect(document.createElement('div')).toBeTruthy()
  })
})

// TF-645f — the npm workspace (Requirements 18.2).
//
// This suite lives in project/tests/frontend/, outside the frontend package it
// tests. The imports above only resolve because the workspace root in project/
// hoists node_modules up to where Node's upward walk from this directory
// finds it. Running `npm install` inside frontend/ instead would leave them
// unresolvable, and the error — "Failed to resolve import" — points at the
// import rather than at the install that caused it.
describe('npm workspace', () => {
  const here = createRequire(import.meta.url)
  const codeRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

  it('hoists node_modules to the workspace root', () => {
    expect(here.resolve('@vue/test-utils'))
      .toContain(path.join(codeRoot, 'node_modules'))
  })

  it('declares the frontend as a workspace member', () => {
    expect(here(path.join(codeRoot, 'package.json')).workspaces).toContain('frontend')
  })

  // Counter-check. Without it the assertions above would pass just as happily
  // if the packages were installed in three places at once — the point is
  // that this directory resolves them and an unrelated one does not.
  it('does not resolve the same package from outside the workspace', () => {
    const outside = createRequire(path.join(os.tmpdir(), 'not-a-real-file.js'))

    expect(() => outside.resolve('@vue/test-utils')).toThrow()
  })
})
