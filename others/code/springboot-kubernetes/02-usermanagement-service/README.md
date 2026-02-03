# 사용자 관리 마이크로서비스

## X-Ray 활성화
### 변경-1: pom.xml
```xml
		<!--  AWS X-Ray -->			
		<dependency>
    		<groupId>com.amazonaws</groupId>
    		<artifactId>aws-xray-recorder-sdk-spring</artifactId>
    		<version>2.6.1</version>
		</dependency>
```

### 변경-2: AwsXrayConfig.java
```java
package com.stacksimplify.restservices.xray;
import javax.servlet.Filter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import com.amazonaws.xray.javax.servlet.AWSXRayServletFilter;

@Configuration
public class AwsXrayConfig {
	@Bean
	public Filter TracingFilter() {
		return new AWSXRayServletFilter("usermanagement-microservice");
	}

}

```

### 변경-3: XRayInspector.java
```java
import java.util.Map;

import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Pointcut;
import org.springframework.stereotype.Component;

import com.amazonaws.xray.entities.Subsegment;
import com.amazonaws.xray.spring.aop.AbstractXRayInterceptor;
@Aspect
@Component
public class XRayInspector extends AbstractXRayInterceptor  {

	@Override
	protected Map<String, Map<String, Object>> generateMetadata(ProceedingJoinPoint proceedingJoinPoint,
			Subsegment subsegment) {
		return super.generateMetadata(proceedingJoinPoint, subsegment);
	}

	@Override
	@Pointcut("@within(com.amazonaws.xray.spring.aop.XRayEnabled) && bean(*)")
	public void xrayEnabledClasses() {
	}

}

```

### 변경-4: 컨트롤러에 @XRayEnabled 추가
```java
@RestController
@XRayEnabled
public class UserController {
}
```
