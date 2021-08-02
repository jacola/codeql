/**
 * Provides classes and predicates for working with the Jackson serialization framework.
 */

import java
private import semmle.code.java.Reflection
private import semmle.code.java.dataflow.DataFlow

private class ObjectMapper extends RefType {
  ObjectMapper() {
    getASupertype*().hasQualifiedName("com.fasterxml.jackson.databind", "ObjectMapper")
  }
}

/** A builder for building Jackson's `JsonMapper`. */
class MapperBuilder extends RefType {
  MapperBuilder() {
    hasQualifiedName("com.fasterxml.jackson.databind.cfg", "MapperBuilder<JsonMapper,Builder>")
  }
}

private class JsonFactory extends RefType {
  JsonFactory() { hasQualifiedName("com.fasterxml.jackson.core", "JsonFactory") }
}

private class JsonParser extends RefType {
  JsonParser() { hasQualifiedName("com.fasterxml.jackson.core", "JsonParser") }
}

/** A type descriptor in Jackson libraries. For example, `java.lang.Class`. */
class JacksonTypeDescriptorType extends RefType {
  JacksonTypeDescriptorType() {
    this instanceof TypeClass or
    hasQualifiedName("com.fasterxml.jackson.databind", "JavaType") or
    hasQualifiedName("com.fasterxml.jackson.core.type", "TypeReference")
  }
}

/** A method in `ObjectMapper` that deserialize data. */
class ObjectMapperReadMethod extends Method {
  ObjectMapperReadMethod() {
    this.getDeclaringType() instanceof ObjectMapper and
    this.hasName(["readValue", "readValues", "treeToValue"])
  }
}

/** A call that enables the default typing in `ObjectMapper`. */
class EnableJacksonDefaultTyping extends MethodAccess {
  EnableJacksonDefaultTyping() {
    this.getMethod().getDeclaringType() instanceof ObjectMapper and
    this.getMethod().hasName("enableDefaultTyping")
  }
}

/** A qualifier of a call to one of the methods in `ObjectMapper` that deserialize data. */
class ObjectMapperReadQualifier extends DataFlow::ExprNode {
  ObjectMapperReadQualifier() {
    exists(MethodAccess ma | ma.getQualifier() = this.asExpr() |
      ma.getMethod() instanceof ObjectMapperReadMethod
    )
  }
}

/** A source that sets a type validator. */
class SetPolymorphicTypeValidatorSource extends DataFlow::ExprNode {
  SetPolymorphicTypeValidatorSource() {
    exists(MethodAccess ma, Method m | m = ma.getMethod() |
      (
        m.getDeclaringType() instanceof ObjectMapper and
        m.hasName("setPolymorphicTypeValidator")
        or
        m.getDeclaringType() instanceof MapperBuilder and
        m.hasName("polymorphicTypeValidator")
      ) and
      this.asExpr() = ma.getQualifier()
    )
  }
}

/** Holds if `fromNode` to `toNode` is a dataflow step that resolves a class. */
predicate resolveClassStep(DataFlow::Node fromNode, DataFlow::Node toNode) {
  exists(ReflectiveClassIdentifierMethodAccess ma |
    ma.getArgument(0) = fromNode.asExpr() and
    ma = toNode.asExpr()
  )
}

/**
 * Holds if `fromNode` to `toNode` is a dataflow step that creates a Jackson parser.
 *
 * For example, a `createParser(userString)` call yields a `JsonParser`, which becomes dangerous
 * if passed to an unsafely-configured `ObjectMapper`'s `readValue` method.
 */
predicate createJacksonJsonParserStep(DataFlow::Node fromNode, DataFlow::Node toNode) {
  exists(MethodAccess ma, Method m | m = ma.getMethod() |
    (m.getDeclaringType() instanceof ObjectMapper or m.getDeclaringType() instanceof JsonFactory) and
    m.hasName("createParser") and
    ma.getArgument(0) = fromNode.asExpr() and
    ma = toNode.asExpr()
  )
}

/**
 * Holds if `fromNode` to `toNode` is a dataflow step that creates a Jackson `TreeNode`.
 *
 * These are parse trees of user-supplied JSON, which may lead to arbitrary code execution
 * if passed to an unsafely-configured `ObjectMapper`'s `treeToValue` method.
 */
predicate createJacksonTreeNodeStep(DataFlow::Node fromNode, DataFlow::Node toNode) {
  exists(MethodAccess ma, Method m | m = ma.getMethod() |
    m.getDeclaringType() instanceof ObjectMapper and
    m.hasName("readTree") and
    ma.getArgument(0) = fromNode.asExpr() and
    ma = toNode.asExpr()
  )
  or
  exists(MethodAccess ma, Method m | m = ma.getMethod() |
    m.getDeclaringType() instanceof JsonParser and
    m.hasName("readValueAsTree") and
    ma.getQualifier() = fromNode.asExpr() and
    ma = toNode.asExpr()
  )
}

/**
 * Holds if `type` or one of its supertypes has a field with `JsonTypeInfo` annotation
 * that enables polymorphic type handling.
 */
private predicate hasJsonTypeInfoAnnotation(RefType type) {
  hasFieldWithJsonTypeAnnotation(type.getASupertype*()) or
  hasJsonTypeInfoAnnotation(type.getAField().getType())
}

/**
 * Holds if `type` has a field with `JsonTypeInfo` annotation
 * that enables polymorphic type handling.
 */
private predicate hasFieldWithJsonTypeAnnotation(RefType type) {
  exists(Annotation a |
    type.getAField().getAnAnnotation() = a and
    a.getType().hasQualifiedName("com.fasterxml.jackson.annotation", "JsonTypeInfo") and
    a.getValue("use").(VarAccess).getVariable().hasName(["CLASS", "MINIMAL_CLASS"])
  )
}

/**
 * Holds if `call` is a method call to a Jackson deserialization method such as `ObjectMapper.readValue(String, Class)`,
 * and the target deserialized class has a field with a `JsonTypeInfo` annotation that enables polymorphic typing.
 */
predicate hasArgumentWithUnsafeJacksonAnnotation(MethodAccess call) {
  call.getMethod() instanceof ObjectMapperReadMethod and
  exists(RefType argType, int i | i > 0 and argType = call.getArgument(i).getType() |
    hasJsonTypeInfoAnnotation(argType.(ParameterizedType).getATypeArgument())
  )
}

/**
 * Holds if `fromNode` to `toNode` is a dataflow step that looks like resolving a class.
 * A method probably resolves a class if it takes a string, returns a type descriptor,
 * and its name contains "resolve", "load", etc.
 *
 * Any method call that satisfies the rule above is assumed to propagate taint from its string arguments,
 * so methods that accept user-controlled data but sanitize it or use it for some
 * completely different purpose before returning a type descriptor could result in false positives.
 */
predicate looksLikeResolveClassStep(DataFlow::Node fromNode, DataFlow::Node toNode) {
  exists(MethodAccess ma, Method m, Expr arg | m = ma.getMethod() and arg = ma.getAnArgument() |
    m.getReturnType() instanceof JacksonTypeDescriptorType and
    m.getName().toLowerCase().regexpMatch("(.*)(resolve|load|class|type)(.*)") and
    arg.getType() instanceof TypeString and
    arg = fromNode.asExpr() and
    ma = toNode.asExpr()
  )
}