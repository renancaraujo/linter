// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../analyzer.dart';

const _desc = r'Avoid overriding a final field to return '
    'different values if called multiple times';

const _details = r'''

**AVOID** overriding or implementing a final field as a getter which could
return different values if it is invoked multiple times on the same receiver.
This could occur because the getter is an implicitly induced getter of a
non-final field, or it could be an explicitly declared getter with a body
that isn't known to return the same value each time it is called.

The underlying motivation for this rule is that if it is followed then a final
field is an immutable property of an object. This is important for correctness
because it is then safe to assume that the value does not change during the
execution of an algorithm. In contrast, it may be necessary to re-check any
other getter repeatedly if it is not known to have this property. Similarly,
it is safe to cache the immutable property in a local variable and promote it,
but for any other property it is necessary to check repeatedly that the
underlying property hasn't changed since it was promoted.

**BAD:**
```dart
class A {
  final int i;
  A(this.i);
}

var j = 0;

class B1 extends A {
  int get i => ++j + super.i; // LINT.
  B1(super.i);
}

class B2 implements A {
  int i; // LINT.
  B2(this.i);
}
```

**GOOD:**
```dart
class C {
  final int i;
  C(this.i);
}

class D1 implements C {
  late final int i = someExpression; // OK.
}

class D2 extends C {
  int get i => super.i + 1; // OK.
  D2(super.i);
}
```

''';

class AvoidUnstableFinalFields extends LintRule {
  AvoidUnstableFinalFields()
      : super(
            name: 'avoid_unstable_final_fields',
            description: _desc,
            details: _details,
            group: Group.errors);

  @override
  void registerNodeProcessors(
      NodeLintRegistry registry, LinterContext context) {
    var visitor = _Visitor(this, context);
    registry.addFieldDeclaration(this, visitor);
    registry.addMethodDeclaration(this, visitor);
  }
}

bool _requiresStability(
    ClassElement classElement, Name name, LinterContext context) {
  // In this first approximation of 'final getters', no other situation
  // can make a getter stable than being the implicitly induced getter
  // of a final instance variable.
  var overriddenList =
      context.inheritanceManager.getOverridden2(classElement, name);
  if (overriddenList == null) return false;
  for (var overridden in overriddenList) {
    if (overridden is PropertyAccessorElement &&
        overridden.isSynthetic &&
        overridden.correspondingSetter == null) {
      return true;
    }
  }
  return false;
}

bool _isStable(PropertyAccessorElement propertyAccessorElement, LinterContext context) {
  var classElement = propertyAccessorElement.enclosingElement;
  assert(propertyAccessorElement.isGetter);
  if (propertyAccessorElement.isSynthetic && propertyAccessorElement.correspondingSetter == null) {
    return true;
  }
  if (classElement is! ClassElement) {
    // This should not happen.
    return false;
  }
  var libraryUri = propertyAccessorElement.library.source.uri;
  var name = Name(libraryUri, propertyAccessorElement.name);
  return _requiresStability(classElement, name, context);
}

abstract class _AbstractVisitor extends SimpleAstVisitor<void> {
  final LintRule rule;
  final LinterContext context;

  // Will be true initially when a getter body is traversed. Will be made
  // true if the getter body turns out to be unstable. Is checked after the
  // traversal of the body, ot emit a lint if it is still false at that time.
  bool isStable = true;

  // Initialized in `visitMethodDeclaration` if a lint might be emitted.
  // It is then guaranteed that `declaration.isGetter` is true.
  late final MethodDeclaration declaration;

  _AbstractVisitor(this.rule, this.context);

  // The following visitor methods will only be executed in the situation
  // where `declaration` is a getter which must be stable, and the
  // traversal is visiting the body of said getter. Hence, a lint must
  // be emitted whenever the given body is not known to be appropriate
  // for a stable getter.

  @override
  void visitAsExpression(AsExpression node) {
    node.expression.accept(this);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    // TODO(eernst): Stable if the right hand side is stable.
    isStable = false;
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    // TODO(eernst): Double check, could it be stable?
    isStable = false;
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    node.leftOperand.accept(this);
    node.rightOperand.accept(this);
    if (isStable) {
      // So far no problems! Only a few cases are working,
      // see if we have one of those.
      if (node.operator.type == TokenType.PLUS) {
        var dartType = node.leftOperand.staticType;
        if (dartType != null) {
          if (dartType.isDartCoreInt || dartType.isDartCoreDouble || dartType.isDartCoreString) {
            // These are all stable.
            return;
          }
          // "Other" cases must be assumed to be unstable.
          isStable = false;
        } else {
          isStable = false;
        }
      }
    }
  }

  @override
  void visitBlock(Block node) {
    // TODO(eernst): Check that only one return statement exists, and it is
    // the last statement in the body, and it returns a stable expression.
    if (node.statements.length == 1) {
      var statement = node.statements.first;
      if (statement is ReturnStatement) {
        statement.accept(this);
      } else {
        // TODO(eernst): Detect further cases where stability holds.
        isStable = false;
      }
    } else {
      // TODO(eernst): Allow multiple statements, just check returns.
      isStable = false;
    }
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    visitBlock(node.block);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    // A cascade is stable if its target is stable.
    node.target.accept(this);
  }

  @override
  visitConditionalExpression(ConditionalExpression node) {
    // TODO(eernst): Stable if all parts are stable.
    isStable = false;
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    node.expression.accept(this);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    node.expression.accept(this);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // We cannot expect the function literal to be the same function, only if
    // we introduce constant expressions that are function literals.
    isStable = false;
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    // We cannot expect a function invocation to be stable, no matter what.
    isStable = false;
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    // The type system does not recognize immutable lists or similar entities,
    // so we can never hope to detect that this is stable.
    isStable = false;
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    // TODO(eernst): Wc eould handle several cases here.
    isStable = false;
  }

  @override
  void visitIsExpression(IsExpression node) {
    // TODO(eernst): Surely we can recognize a stable expression tested for
    // a compile-time constant type, that would be stable.
    isStable = false;
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    node.expression.accept(this);
  }

  @override
  void visitParenthesizedExpression(ParenthesizedExpression node) {
    node.unParenthesized.accept(this);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    // TODO(eernst): !!! This is the most important case.
    isStable = false;
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    // TODO(eernst): Think about this one.
    isStable = false;
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    node.realTarget.accept(this);
    if (isStable) {
      var element = node.propertyName.staticElement;
      if (element == null) {
        // TODO(eernst): When does this occur? Can it be stable?
        isStable = false;
        return;
      }
      if (element is PropertyAccessorElement) {
        if (!_isStable(element, context)) {
          isStable = false;
        }
      }
    }
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    // TODO(eernst): We wouldn't see this, right?
    // If that is true then there is nothing to do.
    isStable = false;
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    node.expression?.accept(this);
  }

  @override
  void visitSuperExpression(SuperExpression node) {
    // This is simply the keyword `super`: Keep it stable!
  }

  @override
  void visitThisExpression(ThisExpression node) {
    // Keep it stable!
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    // Keep it stable!
  }
}

class _MethodVisitor extends _AbstractVisitor {
  late MethodDeclaration declaration;

  _MethodVisitor(super.rule, super.context);

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isGetter) return;
    declaration = node;
    var declaredElement = node.declaredElement;
    if (declaredElement != null) {
      var classElement = declaredElement.enclosingElement as ClassElement;
      var libraryUri = declaredElement.library.source.uri;
      var name = Name(libraryUri, declaredElement.name);
      if (!_requiresStability(classElement, name, context)) return;
      node.body.accept(this);
      if (!isStable) rule.reportLint(node.name);
    }
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final LintRule rule;
  final LinterContext context;

  _Visitor(this.rule, this.context);

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    assert(!node.isStatic);
    Uri? libraryUri;
    Name? name;
    ClassElement? classElement;
    for (var variable in node.fields.variables) {
      var declaredElement = variable.declaredElement;
      if (declaredElement is FieldElement) {
        // A final instance variable can never violate stability.
        if (declaredElement.isFinal) continue;
        // A non-final instance variable is always a violation of stability.
        // Check if stability is required.
        classElement ??= declaredElement.enclosingElement as ClassElement;
        libraryUri ??= declaredElement.library.source.uri;
        name ??= Name(libraryUri, declaredElement.name);
        if (_requiresStability(classElement, name, context)) {
          rule.reportLint(variable.name);
        }
      }
    }
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isStatic && node.isGetter) {
      var visitor = _MethodVisitor(rule, context);
      visitor.visitMethodDeclaration(node);
    }
  }
}